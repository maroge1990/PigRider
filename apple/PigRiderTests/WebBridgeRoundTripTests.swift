import Foundation
import Testing
import WebKit
@testable import PigRider

/// Holds `connect` replies until released, so a test can deliver an event
/// before the reply (replies and events travel on different channels).
@MainActor
final class ReplyGate: BridgeCallHandling {
    private let target: any BridgeCallHandling
    var holdConnectReplies = false
    private(set) var calls: [BridgeCall] = []
    private var held: [@MainActor () -> Void] = []
    private var waiter: CheckedContinuation<Void, Never>?

    init(_ target: any BridgeCallHandling) {
        self.target = target
    }

    func handle(_ call: BridgeCall, origin: String, reply: @escaping @MainActor (BridgeReply) -> Void) {
        calls.append(call)
        guard holdConnectReplies, case .connect = call else {
            target.handle(call, origin: origin, reply: reply)
            return
        }
        target.handle(call, origin: origin) { [weak self] answer in
            self?.held.append { reply(answer) }
            self?.waiter?.resume()
            self?.waiter = nil
        }
    }

    /// Returns once a reply is being held.
    func heldReply() async {
        guard held.isEmpty else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        let replies = held
        held = []
        for reply in replies { reply() }
    }
}

/// Shows the chooser, lets the trainer advertise, and picks it, as a user would.
@MainActor
final class AutoPickPresenter: ChooserPresenting {
    var onPresent: (@MainActor () -> Void)?
    private(set) var presentations = 0

    func present(_ chooser: DeviceChooser, completion: @escaping @MainActor (UUID?) -> Void) {
        presentations += 1
        Task { @MainActor in
            self.onPresent?()
            completion(kickrID)
        }
    }

    func dismiss(_ chooser: DeviceChooser) {}
}

/// A real `WKWebView` with the real polyfill, message handler and event sink,
/// over the real bridge on `FakeCentral`. The fake trainer answers every
/// CoreBluetooth request on the next main-actor turn.
@MainActor
final class RoundTripPage: NSObject, WKNavigationDelegate {
    static let origin = "https://bridge.test"

    let origin: String
    let central = FakeCentral()
    let kickr = FakePeripheral(id: kickrID, name: "KICKR CORE 1234")
    let presenter = AutoPickPresenter()
    let copied = CopiedTexts()
    let bridge: BluetoothBridge
    let gate: ReplyGate
    let webView: WKWebView
    private var loading: CheckedContinuation<Void, any Error>?

    init(polyfill: BridgePolyfill, origin: String = RoundTripPage.origin) {
        self.origin = origin
        let sink = PageEventSink()
        let copied = self.copied
        bridge = BluetoothBridge(central: central, grants: GrantStore(store: InMemoryStore()), events: sink,
                                 chooser: presenter, scheduler: FakeScheduler(), copyText: { copied.texts.append($0) })
        gate = ReplyGate(bridge)
        let handler = BridgeMessageHandler(bridge: gate, origin: origin)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                            configuration: BridgeWebConfiguration.make(polyfill: polyfill, origin: origin,
                                                                       handler: handler))
        sink.page = webView
        super.init()
        webView.navigationDelegate = self

        kickr.gatt = [
            (ftms, [
                DiscoveredCharacteristic(uuid: controlPoint.characteristic, properties: [.write, .indicate]),
                DiscoveredCharacteristic(uuid: bikeData.characteristic, properties: [.notify]),
            ]),
        ]
        central.known = [kickrID: kickr]
        central.onConnect = { [weak self] id in
            Task { @MainActor in self?.bridge.central(didConnect: id) }
        }
        kickr.onCall = { [weak self] call in
            Task { @MainActor in self?.answer(call) }
        }
        presenter.onPresent = { [weak self] in
            guard let self else { return }
            let ad = Advertisement(id: kickrID, name: kickr.name, services: [ftms], manufacturerCompanyIdentifiers: [],
                                   rssi: -55)
            bridge.central(didDiscover: kickr, advertisement: ad)
        }
    }

    private func answer(_ call: FakePeripheral.Call) {
        switch call {
        case .discoverServices:
            bridge.peripheral(kickrID, didDiscoverServices: kickr.gatt.map(\.service), error: nil)
        case .discoverCharacteristics(let service):
            let characteristics = kickr.gatt.first { $0.service == service }?.characteristics ?? []
            bridge.peripheral(kickrID, didDiscoverCharacteristics: characteristics, for: service, error: nil)
        case .setNotify(let key):
            bridge.peripheral(kickrID, didUpdateNotificationStateFor: key, error: nil)
        case .write(_, let key, withResponse: true):
            bridge.peripheral(kickrID, didWriteValueFor: key, error: nil)
        case .write:
            break
        }
    }

    func load(baseURL: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            loading = continuation
            webView.loadHTMLString("<!doctype html><title>bridge test</title>", baseURL: URL(string: baseURL)!)
        }
    }

    /// Runs an async function body in the page's world and returns its result.
    @discardableResult
    func run(_ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading?.resume()
        loading = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loading?.resume(throwing: error)
        loading = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        loading?.resume(throwing: error)
        loading = nil
    }
}

/// The whole path page → polyfill → message handler → bridge → event sink → page.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WebBridgeRoundTripTests {
    let page: RoundTripPage

    init() throws {
        page = RoundTripPage(polyfill: try BridgePolyfill.bundled())
    }

    /// Picks the trainer in the chooser; the page keeps it as `device`.
    static let requestTrainer = """
        globalThis.device = await navigator.bluetooth.requestDevice({ filters: [{ services: [0x1826] }] });
        return device.id;
        """

    @Test func theServerPageGetsTheBridgeOfThisVersion() async throws {
        try await page.load(baseURL: RoundTripPage.origin)
        #expect(try await page.run("return navigator.bluetooth.pigriderBridge.version") as? Int == 1)
    }

    @Test func requestConnectNotifyAndWrite() async throws {
        try await page.load(baseURL: RoundTripPage.origin)
        let id = try await page.run("""
            const device = await navigator.bluetooth.requestDevice({ filters: [{ services: [0x1826] }] });
            const server = await device.gatt.connect();
            const service = await server.getPrimaryService(0x1826);
            const bikeData = await service.getCharacteristic(0x2ad2);
            await bikeData.startNotifications();
            globalThis.firstValue = new Promise((resolve) => bikeData.addEventListener("characteristicvaluechanged",
                (event) => resolve(Array.from(new Uint8Array(event.target.value.buffer))), { once: true }));
            globalThis.controlPoint = await service.getCharacteristic(0x2ad9);
            globalThis.device = device;
            return device.id;
            """)
        #expect(id as? String == kickrID.uuidString)
        #expect(page.presenter.presentations == 1)
        #expect(page.kickr.calls.contains(.setNotify(bikeData)))

        page.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([0x44, 0x02, 0x10]), error: nil)
        #expect(try await page.run("return await firstValue") as? [Int] == [0x44, 0x02, 0x10])

        let connected = try await page.run("""
            await controlPoint.writeValueWithResponse(new Uint8Array([0x11, 0x30]));
            return device.gatt.connected;
            """)
        #expect(connected as? Bool == true)
        #expect(page.kickr.writes == [.write(Data([0x11, 0x30]), controlPoint, withResponse: true)])
    }

    @Test func aDisconnectBeforeTheConnectReplyLeavesTheDeviceDisconnected() async throws {
        try await page.load(baseURL: RoundTripPage.origin)
        try await page.run(Self.requestTrainer)
        page.gate.holdConnectReplies = true
        try await page.run("""
            globalThis.attempt = device.gatt.connect().then(() => "connected", (error) => error.name);
            return null;
            """)
        await page.gate.heldReply()
        page.bridge.central(didDisconnect: kickrID)
        // Scripts run in call order, so once this returns the `disconnected` dispatch has run.
        try await page.run("return null")
        page.gate.release()

        #expect(try await page.run("return await attempt") as? String == "NetworkError")
        #expect(try await page.run("return device.gatt.connected") as? Bool == false)
    }

    @Test func aHomeServerOverPlainHTTPGetsAWorkingBridge() async throws {
        let page = RoundTripPage(polyfill: try BridgePolyfill.bundled(), origin: "http://192.168.1.20:8080")
        try await page.load(baseURL: "http://192.168.1.20:8080/")
        let connected = try await page.run("""
            const device = await navigator.bluetooth.requestDevice({ filters: [{ services: [0x1826] }] });
            await device.gatt.connect();
            return device.gatt.connected;
            """)
        #expect(connected as? Bool == true)
    }

    /// From the address typed in settings to a working bridge: the saved origin
    /// equals WebKit's `location.origin`, so the polyfill installs and calls pass.
    @Test(arguments: ["http://[fd12:3456:0:0:0:0:0:1]:8080", "http://192.168.1.20.:8080", "https://[2001:DB8:0:0::1]"])
    func aTypedServerAddressGetsAWorkingBridge(_ typed: String) async throws {
        let url = try ServerSettings.normalise(typed)
        let origin = try #require(Origin.canonical(url))
        let page = RoundTripPage(polyfill: try BridgePolyfill.bundled(), origin: origin)
        try await page.load(baseURL: url.absoluteString)
        #expect(try await page.run("return location.origin") as? String == origin)
        #expect(try await page.run("return navigator.bluetooth.pigriderBridge.version") as? Int == 1)
        let devices = try await page.run("return (await navigator.bluetooth.getDevices()).length")
        #expect(devices as? Int == 0)
    }

    /// WebKit has no `navigator.clipboard` over plain HTTP: the polyfill's goes to the app's clipboard.
    @Test func aHomeServerOverPlainHTTPCanCopyText() async throws {
        let page = RoundTripPage(polyfill: try BridgePolyfill.bundled(), origin: "http://192.168.1.20:8080")
        try await page.load(baseURL: "http://192.168.1.20:8080/")
        try await page.run("await navigator.clipboard.writeText('OpenRadlr device diagnostics')")
        #expect(page.copied.texts == ["OpenRadlr device diagnostics"])
    }

    @Test func theHTTPTwinOfAnHTTPSServerGetsNoBluetooth() async throws {
        try await page.load(baseURL: "http://bridge.test")
        #expect(try await page.run("return typeof navigator.bluetooth") as? String == "undefined")
        let reply = try await page.run("return await window.webkit.messageHandlers.ble.postMessage({ op: 'getDevices' })")
        let error = (reply as? [String: Any])?["error"] as? [String: Any]
        #expect(error?["name"] as? String == "SecurityError")
        #expect(page.gate.calls.isEmpty)
    }

    @Test func anotherOriginGetsNoBluetoothAndItsMessagesAreRejected() async throws {
        try await page.load(baseURL: "https://other.test")
        #expect(try await page.run("return typeof navigator.bluetooth") as? String == "undefined")
        let reply = try await page.run("return await window.webkit.messageHandlers.ble.postMessage({ op: 'getDevices' })")
        let error = (reply as? [String: Any])?["error"] as? [String: Any]
        #expect(error?["name"] as? String == "SecurityError")
        #expect(page.gate.calls.isEmpty)
    }
}
