import Foundation
@testable import PigRider

@MainActor
final class FakeCentral: CentralManaging {
    var state: CentralState = .poweredOn
    weak var delegate: (any CentralEvents)?
    var isScanning = false
    var connects: [UUID] = []
    var cancels: [UUID] = []
    var known: [UUID: FakePeripheral] = [:]

    func startScan() { isScanning = true }
    func stopScan() { isScanning = false }
    func connect(_ peripheral: any PeripheralHandle) { connects.append(peripheral.identifier) }
    func cancelConnection(_ peripheral: any PeripheralHandle) { cancels.append(peripheral.identifier) }
    func retrievePeripheral(withIdentifier id: UUID) -> (any PeripheralHandle)? { known[id] }
}

@MainActor
final class FakePeripheral: PeripheralHandle {
    enum Call: Equatable {
        case discoverServices
        case discoverCharacteristics(BluetoothUUID)
        case setNotify(CharacteristicKey)
        case write(Data, CharacteristicKey, withResponse: Bool)
    }

    let identifier: UUID
    var name: String?
    var canSendWriteWithoutResponse = true
    /// The GATT table discovery answers from, in order.
    var gatt: [(service: BluetoothUUID, characteristics: [DiscoveredCharacteristic])] = []
    var calls: [Call] = []

    init(id: UUID, name: String?) {
        identifier = id
        self.name = name
    }

    var writes: [Call] { calls.filter { if case .write = $0 { true } else { false } } }
    var discoveries: [Call] {
        calls.filter {
            switch $0 {
            case .discoverServices, .discoverCharacteristics: true
            default: false
            }
        }
    }

    func discoverServices() { calls.append(.discoverServices) }
    func discoverCharacteristics(for service: BluetoothUUID) { calls.append(.discoverCharacteristics(service)) }
    func setNotifyValue(_ enabled: Bool, for key: CharacteristicKey) { calls.append(.setNotify(key)) }
    func writeValue(_ value: Data, for key: CharacteristicKey, withResponse: Bool) {
        calls.append(.write(value, key, withResponse: withResponse))
    }
}

@MainActor
final class FakeEventSink: EventSink {
    var events: [BridgeEvent] = []
    var onSend: (@MainActor (BridgeEvent) -> Void)?

    func send(_ event: BridgeEvent) {
        events.append(event)
        onSend?(event)
    }
}

@MainActor
final class FakeChooserPresenter: ChooserPresenting {
    var chooser: DeviceChooser?
    var completion: (@MainActor (UUID?) -> Void)?
    var presentations = 0
    var dismissals = 0

    func present(_ chooser: DeviceChooser, completion: @escaping @MainActor (UUID?) -> Void) {
        presentations += 1
        self.chooser = chooser
        self.completion = completion
    }

    func dismiss(_ chooser: DeviceChooser) {
        dismissals += 1
        self.chooser = nil
    }

    /// The user's pick; also usable after a dismiss, to simulate a late one.
    func pick(_ id: UUID?) { completion?(id) }
}

@MainActor
final class FakeScheduler: Scheduling {
    private final class Entry: TimerToken {
        let due: Duration
        let action: @MainActor () -> Void
        var cancelled = false

        init(due: Duration, action: @escaping @MainActor () -> Void) {
            self.due = due
            self.action = action
        }

        func cancel() { cancelled = true }
    }

    private(set) var now: Duration = .zero
    private var entries: [Entry] = []

    var pendingCount: Int { entries.filter { !$0.cancelled }.count }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any TimerToken {
        let entry = Entry(due: now + delay, action: action)
        entries.append(entry)
        return entry
    }

    func advance(by delay: Duration) {
        let target = now + delay
        while let next = entries.filter({ !$0.cancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = next.due
            next.cancelled = true
            next.action()
        }
        now = target
        entries.removeAll { $0.cancelled }
    }
}

/// All replies one call received (more than one would be a bug).
@MainActor
final class Replies {
    private(set) var all: [BridgeReply] = []

    func record(_ reply: BridgeReply) { all.append(reply) }

    var isPending: Bool { all.isEmpty }
    var single: BridgeReply? { all.count == 1 ? all[0] : nil }
    var value: ReplyValue? { if case .success(let value)? = single { value } else { nil } }
    var error: BridgeError? { if case .failure(let error)? = single { error } else { nil } }
    var errorName: BridgeError.Name? { error?.name }
    var epoch: Int? { if case .epoch(let epoch)? = value { epoch } else { nil } }
    var succeeded: Bool { value != nil }
}

@MainActor
final class UnsupportedLog {
    var methods: [String] = []
}

// The KICKR's GATT table used across the bridge tests.
let ftms = uuid("1826")
let cyclingPower = uuid("1818")
let heartRate = uuid("180d")
/// Fitness Machine Control Point: write + indicate.
let controlPoint = CharacteristicKey(service: ftms, characteristic: uuid("2ad9"))
/// Indoor Bike Data: notify only.
let bikeData = CharacteristicKey(service: ftms, characteristic: uuid("2ad2"))
/// A write-without-response characteristic (as on a Zwift Click).
let commandChannel = CharacteristicKey(service: ftms, characteristic: uuid("2ada"))
/// Cycling Power Measurement: notify.
let powerMeasurement = CharacteristicKey(service: cyclingPower, characteristic: uuid("2a63"))
let polarID = UUID(uuidString: "0A0B0C0D-0000-4000-8000-000000000002")!

@MainActor
final class BridgeHarness {
    static let origin = "https://ride.example.com"
    static let otherOrigin = "https://other.example.com"

    let central = FakeCentral()
    let sink = FakeEventSink()
    let presenter = FakeChooserPresenter()
    let scheduler = FakeScheduler()
    let store = InMemoryStore()
    let unsupported = UnsupportedLog()
    let grants: GrantStore
    let bridge: BluetoothBridge
    let kickr = FakePeripheral(id: kickrID, name: "KICKR CORE 1234")
    let polar = FakePeripheral(id: polarID, name: "Polar H10")
    /// Events and replies in the order they happened.
    var log: [String] = []
    private var answered: [UUID: Int] = [:]

    init() {
        grants = GrantStore(store: store)
        let unsupported = self.unsupported
        bridge = BluetoothBridge(central: central, grants: grants, events: sink, chooser: presenter,
                                 scheduler: scheduler, onUnsupported: { unsupported.methods.append($0) })
        kickr.gatt = [
            (ftms, [
                DiscoveredCharacteristic(uuid: controlPoint.characteristic, properties: [.write, .indicate]),
                DiscoveredCharacteristic(uuid: bikeData.characteristic, properties: [.notify]),
                DiscoveredCharacteristic(uuid: commandChannel.characteristic, properties: [.writeWithoutResponse, .notify]),
            ]),
            (cyclingPower, [DiscoveredCharacteristic(uuid: powerMeasurement.characteristic, properties: [.notify])]),
        ]
        polar.gatt = [(heartRate, [DiscoveredCharacteristic(uuid: uuid("2a37"), properties: [.notify])])]
        central.known = [kickrID: kickr, polarID: polar]
        sink.onSend = { [weak self] event in
            switch event {
            case .disconnected(_, let epoch): self?.log.append("event disconnected \(epoch)")
            case .value: self?.log.append("event value")
            case .advertisement: self?.log.append("event advertisement")
            }
        }
    }

    @discardableResult
    func call(_ call: BridgeCall, origin: String = BridgeHarness.origin) -> Replies {
        let replies = Replies()
        bridge.handle(call, origin: origin) { [weak self] reply in
            replies.record(reply)
            switch reply {
            case .success: self?.log.append("reply ok")
            case .failure(let error): self?.log.append("reply \(error.name.rawValue)")
            }
        }
        return replies
    }

    func grant(_ id: UUID = kickrID, services: [BluetoothUUID] = [ftms, cyclingPower], origin: String = BridgeHarness.origin) {
        grants.grant(origin: origin, id: id, name: id == kickrID ? "KICKR CORE 1234" : "Polar H10", services: services)
    }

    /// Grants (unless already granted) and connects; returns the epoch.
    @discardableResult
    func connect(_ id: UUID = kickrID) -> Int? {
        if grants.grant(origin: Self.origin, id: id) == nil { grant(id, services: id == kickrID ? [ftms, cyclingPower] : [heartRate]) }
        let replies = call(.connect(id: id))
        bridge.central(didConnect: id)
        return replies.epoch
    }

    func peripheral(_ id: UUID) -> FakePeripheral { id == kickrID ? kickr : polar }

    /// Answers every discovery request the peripheral has not had an answer to yet.
    func answerDiscoveries(_ id: UUID = kickrID) {
        let fake = peripheral(id)
        while answered[id, default: 0] < fake.calls.count {
            let call = fake.calls[answered[id, default: 0]]
            answered[id, default: 0] += 1
            switch call {
            case .discoverServices:
                bridge.peripheral(id, didDiscoverServices: fake.gatt.map(\.service), error: nil)
            case .discoverCharacteristics(let service):
                let characteristics = fake.gatt.first { $0.service == service }?.characteristics ?? []
                bridge.peripheral(id, didDiscoverCharacteristics: characteristics, for: service, error: nil)
            default:
                break
            }
        }
    }

    /// Resolves a characteristic (running discovery) so later operations need no discovery.
    func resolve(_ key: CharacteristicKey, id: UUID = kickrID) {
        let replies = call(.getCharacteristic(id: id, key: key))
        answerDiscoveries(id)
        precondition(replies.succeeded, "could not resolve \(key)")
    }

    func sighting(_ id: UUID, name: String?, services: [BluetoothUUID] = [], companies: [UInt16] = [],
                  rssi: Int = -60) {
        let ad = Advertisement(id: id, name: name, services: Set(services),
                               manufacturerCompanyIdentifiers: Set(companies), rssi: rssi)
        bridge.central(didDiscover: peripheral(id), advertisement: ad)
    }

    @discardableResult
    func write(_ key: CharacteristicKey, _ bytes: [UInt8], withResponse: Bool = true) -> Replies {
        call(.writeValue(id: kickrID, key: key, value: Data(bytes), withResponse: withResponse))
    }
}
