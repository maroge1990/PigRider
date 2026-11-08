import Foundation

/// The native side of the Web Bluetooth bridge: executes the protocol in
/// `apple/docs/bridge-protocol.md` on top of CoreBluetooth.
///
/// API for the web view (T7):
/// - `init(central:grants:events:chooser:scheduler:onUnsupported:)`. The bridge
///   makes itself the central's delegate. `BluetoothBridge.live(...)` builds
///   one on CoreBluetooth.
/// - `handle(_:origin:reply:)`: one call, decoded with `BridgeCall.decode`,
///   from a page of the canonical `origin`. `reply` runs exactly once, on the
///   main actor; send `BridgeReply.jsonObject` back to the page.
/// - `documentDidChange()`: a main-frame navigation committed, or the web
///   content process died. Cancels every connection, scan consumer and the
///   chooser; pending calls reject with `AbortError`; nothing late reaches
///   the new document. Grants stay.
/// - `serverDidChange()`: the server URL changed; same as a new document.
/// - `enterBackground()` / `enterForeground()`: the scene's background state
///   (not "inactive"). Connections end on background; on foreground the page
///   gets `disconnected` for each device that was connected and reconnects.
/// Events go out through the `EventSink`, in the order they happen.
/// A link we cancel drains: new connects wait until CoreBluetooth answers the
/// cancel or reports the peripheral `.disconnected`, so no late callback of
/// the cancelled link can reach a newer connection, in this document or the next.
@MainActor
final class BluetoothBridge {
    /// A GATT operation without a callback for this long ends the connection.
    static let gattTimeout: Duration = .seconds(10)
    /// How long a cancelled link waits for CoreBluetooth's answer before the
    /// bridge looks at the peripheral's state instead (CoreBluetooth may never
    /// answer the cancel of a pending connect). A local cancel of a link whose
    /// peer has gone quiet can take up to the supervision timeout, which Apple's
    /// accessory guidelines cap at 6 s; and 6 s leaves a queued connect 9 s of
    /// the page's 15 s.
    static let drainTimeout: Duration = .seconds(6)

    private let central: any CentralManaging
    private let grants: GrantStore
    private let events: any EventSink
    private let chooserPresenter: any ChooserPresenting
    private let scheduler: any Scheduling
    private let onUnsupported: @MainActor (String) -> Void
    private let scan: ScanCoordinator

    private var nextReplyID = 0
    private var outstanding: [Int: PendingReply] = [:]
    private var epochs: [UUID: Int] = [:]
    private var links: [UUID: Link] = [:]
    private var knownPeripherals: [UUID: any PeripheralHandle] = [:]
    private var watches: [String: Watch] = [:]
    private var openChooser: ChooserSession?
    private var isInBackground = false
    private var connectedBeforeBackground: [(id: UUID, epoch: Int)] = []

    init(central: any CentralManaging, grants: GrantStore, events: any EventSink, chooser: any ChooserPresenting,
         scheduler: any Scheduling = TaskScheduler(), onUnsupported: @escaping @MainActor (String) -> Void = { _ in }) {
        self.central = central
        self.grants = grants
        self.events = events
        self.chooserPresenter = chooser
        self.scheduler = scheduler
        self.onUnsupported = onUnsupported
        scan = ScanCoordinator(scanner: central)
        central.delegate = self
    }

    // MARK: Calls

    func handle(_ call: BridgeCall, origin: String, reply callback: @escaping @MainActor (BridgeReply) -> Void) {
        let reply = register(callback)
        switch call {
        case let .requestDevice(filters, optionalServices):
            requestDevice(filters: filters, optionalServices: optionalServices, origin: origin, reply: reply)
        case .getDevices:
            reply.succeed(.devices(grants.devices(for: origin).map { DeviceInfo(id: $0.id, name: $0.name) }))
        case .forget(let id):
            forget(id, origin: origin)
            reply.succeed()
        case let .watchAdvertisements(id, watchId):
            watchAdvertisements(id, watchId: watchId, origin: origin, reply: reply)
        case .unwatchAdvertisements(let watchId):
            unwatch(watchId)
            reply.succeed()
        case .connect(let id):
            connect(id, origin: origin, reply: reply)
        case let .disconnect(id, epoch):
            disconnect(id, epoch: epoch, origin: origin, reply: reply)
        case let .getPrimaryService(id, service):
            getPrimaryService(id, service: service, origin: origin, reply: reply)
        case let .getCharacteristic(id, key):
            withCharacteristic(id, key, origin: origin, reply: reply) { characteristic, _, _ in
                reply.succeed(.properties(characteristic.properties))
            }
        case let .startNotifications(id, key):
            withCharacteristic(id, key, origin: origin, reply: reply) { [weak self] characteristic, link, session in
                guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                    reply.fail(BridgeError(.notSupportedError, "Characteristic does not support notifications."))
                    return
                }
                self?.enqueue(GattOp(kind: .notify, reply: reply), key: key, id: id, link: link, session: session)
            }
        case let .writeValue(id, key, value, withResponse):
            withCharacteristic(id, key, origin: origin, reply: reply) { [weak self] characteristic, link, session in
                let needed: CharacteristicProperties = withResponse ? .write : .writeWithoutResponse
                guard characteristic.properties.contains(needed) else {
                    let kind = withResponse ? "write" : "write without response"
                    reply.fail(BridgeError(.notSupportedError, "Characteristic does not support \(kind)."))
                    return
                }
                let op = GattOp(kind: .write(value, withResponse: withResponse), reply: reply)
                self?.enqueue(op, key: key, id: id, link: link, session: session)
            }
        case .reportUnsupported(let method):
            onUnsupported(method)
            reply.succeed()
        }
    }

    // MARK: Lifecycle

    func documentDidChange() {
        let pending = outstanding.sorted { $0.key < $1.key }.map(\.value)
        outstanding = [:]
        for reply in pending { reply.fail(.documentChanged) }
        for (id, link) in links { teardown(id, link, cancel: true, emit: false, error: .documentChanged) }
        scan.removeAll()
        watches = [:]
        if let session = openChooser {
            openChooser = nil
            chooserPresenter.dismiss(session.chooser)
        }
        connectedBeforeBackground = []
    }

    func serverDidChange() {
        documentDidChange()
    }

    func enterBackground() {
        guard !isInBackground else { return }
        isInBackground = true
        let background = BridgeError(.networkError, "The app moved to the background.")
        for (id, link) in links.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if link.session != nil { connectedBeforeBackground.append((id, epochs[id, default: 0])) }
            teardown(id, link, cancel: true, emit: false, error: background)
        }
        // Anything queued for the old epochs (values delivered on return) is now stale.
        for id in epochs.keys { epochs[id, default: 0] += 1 }
        scan.pause()
    }

    func enterForeground() {
        guard isInBackground else { return }
        isInBackground = false
        scan.resume()
        let dropped = connectedBeforeBackground
        connectedBeforeBackground = []
        for (id, epoch) in dropped { events.send(.disconnected(id: id, epoch: epoch)) }
    }

    // MARK: Devices and scanning

    private func requestDevice(filters: [RequestFilter], optionalServices: [BluetoothUUID], origin: String,
                               reply: PendingReply) {
        guard openChooser == nil else {
            reply.fail(BridgeError(.invalidStateError, "A device chooser is already open."))
            return
        }
        if let error = Self.unavailableError(central.state) {
            reply.fail(error)
            return
        }
        let chooser = DeviceChooser(filters: filters)
        let token = scan.addConsumer { chooser.record($0) }
        let services = filters.flatMap { $0.services ?? [] } + optionalServices
        let session = ChooserSession(chooser: chooser, token: token, reply: reply, origin: origin, services: services)
        openChooser = session
        chooserPresenter.present(chooser) { [weak self, weak session] picked in
            guard let self, let session else { return }
            self.chooserFinished(session, picked: picked)
        }
    }

    private func chooserFinished(_ session: ChooserSession, picked: UUID?) {
        guard openChooser === session else { return }
        openChooser = nil
        scan.removeConsumer(session.token)
        guard let picked, let device = session.chooser.device(picked) else {
            session.reply.fail(.noDeviceSelected)
            return
        }
        let name = device.name ?? knownPeripherals[picked]?.name
        grants.grant(origin: session.origin, id: picked, name: name, services: session.services)
        session.reply.succeed(.device(DeviceInfo(id: picked, name: name)))
    }

    private func forget(_ id: UUID, origin: String) {
        guard grants.grant(origin: origin, id: id) != nil else { return }
        grants.revoke(origin: origin, id: id)
        for (watchId, watch) in watches where watch.deviceID == id { unwatch(watchId) }
        if let link = links[id] { teardown(id, link, cancel: true, emit: true, error: .disconnected) }
    }

    private func watchAdvertisements(_ id: UUID, watchId: String, origin: String, reply: PendingReply) {
        guard grants.grant(origin: origin, id: id) != nil else {
            reply.fail(.deviceNotFound)
            return
        }
        unwatch(watchId)
        let token = scan.addConsumer { [weak self] ad in
            guard ad.id == id else { return }
            self?.events.send(.advertisement(watchId: watchId, id: id, name: ad.name, rssi: ad.rssi))
        }
        watches[watchId] = Watch(deviceID: id, token: token)
        reply.succeed()
    }

    private func unwatch(_ watchId: String) {
        guard let watch = watches.removeValue(forKey: watchId) else { return }
        scan.removeConsumer(watch.token)
    }

    private static func unavailableError(_ state: CentralState) -> BridgeError? {
        switch state {
        case .poweredOff: BridgeError(.notFoundError, "Bluetooth is turned off.")
        case .unauthorized: BridgeError(.notFoundError, "Bluetooth permission is denied for PigRider.")
        case .unsupported: BridgeError(.notFoundError, "Bluetooth is not supported on this device.")
        case .unknown, .resetting, .poweredOn: nil
        }
    }

    // MARK: Connections

    private func connect(_ id: UUID, origin: String, reply: PendingReply) {
        guard grants.grant(origin: origin, id: id) != nil else {
            reply.fail(.deviceNotFound)
            return
        }
        guard !isInBackground else {
            reply.fail(BridgeError(.networkError, "The app is in the background."))
            return
        }
        guard central.state == .poweredOn else {
            reply.fail(BridgeError(.networkError, "Bluetooth is not available."))
            return
        }
        guard let link = link(for: id) else {
            reply.fail(BridgeError(.networkError, "Device is not available."))
            return
        }
        if case .draining(let drain) = link.state, drain.expired {
            // Past the drain timeout only CoreBluetooth's own state can end the fence.
            guard link.handle.state == .disconnected else {
                reply.fail(.previousLinkOpen)
                return
            }
            finishDraining(link)
        }
        // The epoch is assigned before CoreBluetooth is asked, and every attempt gets its own.
        epochs[id, default: 0] += 1
        let epoch = epochs[id, default: 0]
        let attempt = Attempt(epoch: epoch, reply: reply)
        switch link.state {
        case .idle:
            link.state = .connecting([attempt])
            central.connect(link.handle)
        case .connecting(let attempts):
            link.state = .connecting(attempts + [attempt])
        case .connected:
            reply.succeed(.epoch(epoch))
        case .draining(let drain):
            // Until CoreBluetooth has answered our cancel, a didConnect could be the old attempt's.
            drain.queued.append(attempt)
        }
    }

    private func disconnect(_ id: UUID, epoch: Int?, origin: String, reply: PendingReply) {
        guard grants.grant(origin: origin, id: id) != nil else {
            reply.fail(.deviceNotFound)
            return
        }
        // A stale epoch must never cut a newer connection.
        if epoch == nil || epoch == epochs[id], let link = links[id] {
            teardown(id, link, cancel: true, emit: true, error: .disconnected)
        }
        reply.succeed()
    }

    private func link(for id: UUID) -> Link? {
        if let link = links[id] { return link }
        guard let handle = knownPeripherals[id] ?? central.retrievePeripheral(withIdentifier: id) else { return nil }
        let link = Link(handle: handle)
        links[id] = link
        return link
    }

    /// Ends a link: `disconnected` (if it was connected and `emit`) goes out
    /// first, then every pending attempt and operation rejects with `error`.
    /// With `cancel`, the link drains until CoreBluetooth answers the cancel;
    /// without, CoreBluetooth has already let it go (or never will answer).
    private func teardown(_ id: UUID, _ link: Link, cancel: Bool, emit: Bool, error: BridgeError) {
        let previous = link.state
        switch previous {
        case .idle:
            return
        case .draining(let drain):
            // Already cancelled; only the queued attempts end here.
            if !cancel {
                drain.timer?.cancel()
                link.state = .idle
            }
            let queued = drain.queued
            drain.queued = []
            for attempt in queued { attempt.reply.fail(error) }
            return
        case .connecting, .connected:
            break
        }
        if cancel {
            central.cancelConnection(link.handle)
            startDraining(link)
        } else {
            link.state = .idle
        }
        switch previous {
        case .idle, .draining:
            break
        case .connecting(let attempts):
            for attempt in attempts { attempt.reply.fail(error) }
        case .connected(let session):
            if emit { events.send(.disconnected(id: id, epoch: epochs[id, default: 0])) }
            session.invalidate(error)
        }
    }

    private func startDraining(_ link: Link) {
        let drain = Drain()
        link.state = .draining(drain)
        drain.timer = scheduler.schedule(after: Self.drainTimeout) { [weak self, weak link, weak drain] in
            guard let self, let link, let drain else { return }
            self.drainTimedOut(link, drain)
        }
    }

    /// No answer to our cancel. The timer alone never ends the fence: only
    /// CoreBluetooth's own state saying the link is gone does.
    private func drainTimedOut(_ link: Link, _ drain: Drain) {
        guard case .draining(let current) = link.state, current === drain else { return }
        drain.timer = nil
        if link.handle.state == .disconnected {
            finishDraining(link)
            return
        }
        // CoreBluetooth still holds the old link: ask again, and let the page retry later.
        central.cancelConnection(link.handle)
        drain.expired = true
        let queued = drain.queued
        drain.queued = []
        for attempt in queued { attempt.reply.fail(.previousLinkOpen) }
    }

    /// CoreBluetooth has answered our cancel or no longer holds the link:
    /// connects queued meanwhile now start a fresh connection.
    private func finishDraining(_ link: Link) {
        guard case .draining(let drain) = link.state else { return }
        drain.timer?.cancel()
        if drain.queued.isEmpty {
            link.state = .idle
        } else {
            link.state = .connecting(drain.queued)
            central.connect(link.handle)
        }
    }

    // MARK: GATT

    private func connectedLink(_ id: UUID, service: BluetoothUUID, origin: String,
                               reply: PendingReply) -> (Link, Session)? {
        guard let grant = grants.grant(origin: origin, id: id) else {
            reply.fail(.deviceNotFound)
            return nil
        }
        guard grant.services.contains(service) else {
            reply.fail(.serviceNotAllowed)
            return nil
        }
        guard let link = links[id], let session = link.session else {
            reply.fail(.gattDisconnected)
            return nil
        }
        return (link, session)
    }

    private func getPrimaryService(_ id: UUID, service: BluetoothUUID, origin: String, reply: PendingReply) {
        guard let (link, session) = connectedLink(id, service: service, origin: origin, reply: reply) else { return }
        discoverServices(id, link, session) { result in
            switch result {
            case .failure(let error): reply.fail(error)
            case .success(let services):
                if services.contains(service) { reply.succeed() } else { reply.fail(.serviceNotFound) }
            }
        }
    }

    /// Resolves a characteristic through the per-connection discovery cache.
    private func withCharacteristic(_ id: UUID, _ key: CharacteristicKey, origin: String, reply: PendingReply,
                                    _ body: @escaping @MainActor (DiscoveredCharacteristic, Link, Session) -> Void) {
        guard let (link, session) = connectedLink(id, service: key.service, origin: origin, reply: reply) else { return }
        discoverServices(id, link, session) { [weak self] result in
            switch result {
            case .failure(let error):
                reply.fail(error)
            case .success(let services):
                guard services.contains(key.service) else {
                    reply.fail(.serviceNotFound)
                    return
                }
                self?.discoverCharacteristics(id, link, session, service: key.service) { result in
                    switch result {
                    case .failure(let error):
                        reply.fail(error)
                    case .success(let characteristics):
                        guard let characteristic = characteristics.first(where: { $0.uuid == key.characteristic }) else {
                            reply.fail(.characteristicNotFound)
                            return
                        }
                        body(characteristic, link, session)
                    }
                }
            }
        }
    }

    private func discoverServices(_ id: UUID, _ link: Link, _ session: Session,
                                  _ completion: @escaping Discovery<[BluetoothUUID]>.Waiter) {
        session.services.run(completion) {
            let timer = startTimeout(id, session)
            link.handle.discoverServices()
            return timer
        }
    }

    private func discoverCharacteristics(_ id: UUID, _ link: Link, _ session: Session, service: BluetoothUUID,
                                         _ completion: @escaping Discovery<[DiscoveredCharacteristic]>.Waiter) {
        session.characteristicDiscovery(for: service).run(completion) {
            let timer = startTimeout(id, session)
            link.handle.discoverCharacteristics(for: service)
            return timer
        }
    }

    private func enqueue(_ op: GattOp, key: CharacteristicKey, id: UUID, link: Link, session: Session) {
        guard link.session === session else {
            op.reply.fail(.gattDisconnected)
            return
        }
        session.queues[key, default: []].append(op)
        pump(key, id: id, link: link, session: session)
    }

    /// Starts the head of a characteristic's FIFO unless one is in flight.
    private func pump(_ key: CharacteristicKey, id: UUID, link: Link, session: Session) {
        while link.session === session, session.inFlight[key] == nil, let op = session.queues[key]?.first {
            switch op.kind {
            case .notify:
                session.inFlight[key] = startTimeout(id, session)
                link.handle.setNotifyValue(true, for: key)
            case .write(let value, withResponse: true):
                session.inFlight[key] = startTimeout(id, session)
                link.handle.writeValue(value, for: key, withResponse: true)
            case .write(let value, withResponse: false):
                if link.handle.canSendWriteWithoutResponse {
                    session.queues[key]?.removeFirst()
                    link.handle.writeValue(value, for: key, withResponse: false)
                    op.reply.succeed()
                } else {
                    session.inFlight[key] = startTimeout(id, session)
                    session.waitingForReady.append(key)
                }
            }
        }
    }

    /// Matches a callback to the head of its FIFO, only while the connection
    /// the queue belongs to is current; anything else is dropped.
    private func complete(_ id: UUID, _ key: CharacteristicKey, error: BridgeError?,
                          matching: (GattOp.Kind) -> Bool) {
        guard let link = links[id], let session = link.session, let op = session.queues[key]?.first,
              matching(op.kind), let timer = session.inFlight[key] else { return }
        timer.cancel()
        session.inFlight[key] = nil
        session.queues[key]?.removeFirst()
        if let error { op.reply.fail(error) } else { op.reply.succeed() }
        pump(key, id: id, link: link, session: session)
    }

    private func startTimeout(_ id: UUID, _ session: Session) -> any TimerToken {
        scheduler.schedule(after: Self.gattTimeout) { [weak self, weak session] in
            guard let self, let session, let link = self.links[id], link.session === session else { return }
            self.teardown(id, link, cancel: true, emit: true, error: .timedOut)
        }
    }

    // MARK: Replies

    private func register(_ callback: @escaping @MainActor (BridgeReply) -> Void) -> PendingReply {
        nextReplyID += 1
        let id = nextReplyID
        let reply = PendingReply(callback: callback) { [weak self] in self?.outstanding[id] = nil }
        outstanding[id] = reply
        return reply
    }
}

// MARK: - CoreBluetooth callbacks

extension BluetoothBridge: CentralEvents {
    func centralDidUpdateState() {
        scan.availabilityChanged()
        let state = central.state
        if state != .poweredOn {
            let unavailable = BridgeError(.networkError, "Bluetooth is not available.")
            // CoreBluetooth answers no outstanding cancel once it is unavailable.
            for (id, link) in links { teardown(id, link, cancel: false, emit: true, error: unavailable) }
        }
        if let session = openChooser, let error = Self.unavailableError(state) {
            openChooser = nil
            scan.removeConsumer(session.token)
            chooserPresenter.dismiss(session.chooser)
            session.reply.fail(error)
        }
    }

    func central(didDiscover peripheral: any PeripheralHandle, advertisement: Advertisement) {
        knownPeripherals[advertisement.id] = peripheral
        scan.deliver(advertisement)
    }

    func central(didConnect id: UUID) {
        // While draining, this is the cancelled attempt's link; its didDisconnect follows.
        guard let link = links[id], case .connecting(let attempts) = link.state else { return }
        link.state = .connected(Session())
        // Each pending attempt gets its own epoch; later events carry the newest.
        for attempt in attempts { attempt.reply.succeed(.epoch(attempt.epoch)) }
    }

    func central(didFailToConnect id: UUID) {
        guard let link = links[id] else { return }
        switch link.state {
        case .draining:
            finishDraining(link)
        case .connecting:
            teardown(id, link, cancel: false, emit: false, error: BridgeError(.networkError, "Connection failed."))
        case .idle, .connected:
            break
        }
    }

    func central(didDisconnect id: UUID) {
        guard let link = links[id] else { return }
        if case .draining = link.state {
            // The answer to our own cancel.
            finishDraining(link)
            return
        }
        teardown(id, link, cancel: false, emit: true, error: .disconnected)
    }

    func peripheral(_ id: UUID, didDiscoverServices services: [BluetoothUUID], error: BridgeError?) {
        guard let session = links[id]?.session else { return }
        session.services.finish(error.map { .failure($0) } ?? .success(services))
    }

    func peripheral(_ id: UUID, didDiscoverCharacteristics characteristics: [DiscoveredCharacteristic],
                    for service: BluetoothUUID, error: BridgeError?) {
        guard let session = links[id]?.session else { return }
        session.characteristics[service]?.finish(error.map { .failure($0) } ?? .success(characteristics))
    }

    func peripheral(_ id: UUID, didUpdateNotificationStateFor key: CharacteristicKey, error: BridgeError?) {
        complete(id, key, error: error) { if case .notify = $0 { true } else { false } }
    }

    func peripheral(_ id: UUID, didWriteValueFor key: CharacteristicKey, error: BridgeError?) {
        complete(id, key, error: error) { if case .write(_, withResponse: true) = $0 { true } else { false } }
    }

    func peripheral(_ id: UUID, didUpdateValueFor key: CharacteristicKey, value: Data?, error: BridgeError?) {
        guard links[id]?.session != nil, error == nil, let value else { return }
        events.send(.value(id: id, epoch: epochs[id, default: 0], key: key, value: value))
    }

    func peripheralIsReadyToSendWriteWithoutResponse(_ id: UUID) {
        guard let link = links[id], let session = link.session else { return }
        let waiting = session.waitingForReady
        session.waitingForReady = []
        for key in waiting {
            session.inFlight.removeValue(forKey: key)?.cancel()
            pump(key, id: id, link: link, session: session)
        }
    }
}

// MARK: - State

extension BridgeError {
    static let serviceNotFound = BridgeError(.notFoundError, "Service not found.")
    static let characteristicNotFound = BridgeError(.notFoundError, "Characteristic not found.")
    static let previousLinkOpen = BridgeError(.networkError, "The previous connection has not closed yet.")
}

/// A reply that is sent exactly once; later sends are dropped.
@MainActor
private final class PendingReply {
    private var callback: (@MainActor (BridgeReply) -> Void)?
    private let onFinish: @MainActor () -> Void

    init(callback: @escaping @MainActor (BridgeReply) -> Void, onFinish: @escaping @MainActor () -> Void) {
        self.callback = callback
        self.onFinish = onFinish
    }

    func send(_ reply: BridgeReply) {
        guard let callback else { return }
        self.callback = nil
        onFinish()
        callback(reply)
    }

    func succeed(_ value: ReplyValue = .none) { send(.success(value)) }
    func fail(_ error: BridgeError) { send(.failure(error)) }
}

private struct Attempt {
    let epoch: Int
    let reply: PendingReply
}

private struct Watch {
    let deviceID: UUID
    let token: ScanCoordinator.Token
}

@MainActor
private final class ChooserSession {
    let chooser: DeviceChooser
    let token: ScanCoordinator.Token
    let reply: PendingReply
    let origin: String
    let services: [BluetoothUUID]

    init(chooser: DeviceChooser, token: ScanCoordinator.Token, reply: PendingReply, origin: String,
         services: [BluetoothUUID]) {
        self.chooser = chooser
        self.token = token
        self.reply = reply
        self.origin = origin
        self.services = services
    }
}

/// One peripheral's link. CoreBluetooth has one connection per peripheral,
/// shared by every connect attempt.
@MainActor
private final class Link {
    enum State {
        case idle
        case connecting([Attempt])
        case connected(Session)
        /// We cancelled the link and CoreBluetooth's answer (didDisconnect or
        /// didFailToConnect) is still to come. A didConnect or GATT callback
        /// now belongs to the cancelled link and is ignored; connects queue.
        case draining(Drain)
    }

    let handle: any PeripheralHandle
    var state: State = .idle

    init(handle: any PeripheralHandle) {
        self.handle = handle
    }

    var session: Session? {
        if case .connected(let session) = state { session } else { nil }
    }
}

/// A cancel waiting for CoreBluetooth's answer, and the connects that wait for it.
@MainActor
private final class Drain {
    var queued: [Attempt] = []
    /// Checks CoreBluetooth's state if it never answers (`drainTimeout`).
    var timer: (any TimerToken)?
    /// The timeout passed while CoreBluetooth still held the link: connects
    /// now go ahead only once its state is `.disconnected`, else reject.
    var expired = false
}

private struct GattOp {
    enum Kind {
        case notify
        case write(Data, withResponse: Bool)
    }

    let kind: Kind
    let reply: PendingReply
}

/// One connection's GATT state: discovery cache and per-characteristic FIFOs.
/// Thrown away when the connection ends, so late callbacks find nothing.
@MainActor
private final class Session {
    let services = Discovery<[BluetoothUUID]>()
    var characteristics: [BluetoothUUID: Discovery<[DiscoveredCharacteristic]>] = [:]
    var queues: [CharacteristicKey: [GattOp]] = [:]
    /// Timeout of each queue's head while CoreBluetooth works on it.
    var inFlight: [CharacteristicKey: any TimerToken] = [:]
    var waitingForReady: [CharacteristicKey] = []

    func characteristicDiscovery(for service: BluetoothUUID) -> Discovery<[DiscoveredCharacteristic]> {
        if let discovery = characteristics[service] { return discovery }
        let discovery = Discovery<[DiscoveredCharacteristic]>()
        characteristics[service] = discovery
        return discovery
    }

    func invalidate(_ error: BridgeError) {
        for timer in inFlight.values { timer.cancel() }
        inFlight = [:]
        waitingForReady = []
        services.fail(error)
        for discovery in characteristics.values { discovery.fail(error) }
        characteristics = [:]
        let ops = queues.values.flatMap { $0 }
        queues = [:]
        for op in ops { op.reply.fail(error) }
    }
}

/// A discovery run once per connection; callers during the run wait for it.
@MainActor
private final class Discovery<Value> {
    typealias Waiter = @MainActor (Result<Value, BridgeError>) -> Void

    private var value: Value?
    private var waiters: [Waiter] = []
    private var timer: (any TimerToken)?

    func run(_ waiter: @escaping Waiter, start: () -> any TimerToken) {
        if let value {
            waiter(.success(value))
            return
        }
        waiters.append(waiter)
        if timer == nil { timer = start() }
    }

    /// A callback; ignored unless a run is in progress.
    func finish(_ result: Result<Value, BridgeError>) {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        if case .success(let value) = result { self.value = value }
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter(result) }
    }

    func fail(_ error: BridgeError) {
        timer?.cancel()
        timer = nil
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter(.failure(error)) }
    }
}
