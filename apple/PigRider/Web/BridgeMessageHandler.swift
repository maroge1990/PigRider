import Foundation
import WebKit

/// What the bridge needs from the message handler: one decoded call from a
/// page of `origin`. `BluetoothBridge` is the real one; tests put fakes or
/// decorators here.
@MainActor
protocol BridgeCallHandling: AnyObject {
    func handle(_ call: BridgeCall, origin: String, reply: @escaping @MainActor (BridgeReply) -> Void)
}

extension BluetoothBridge: BridgeCallHandling {}

/// Where a message came from: the frame kind and its canonical origin.
struct MessageSource: Equatable, Sendable {
    let isMainFrame: Bool
    let origin: String?

    /// `port` 0 is the scheme's default, as `WKSecurityOrigin` reports it.
    init(isMainFrame: Bool, scheme: String, host: String, port: Int) {
        self.isMainFrame = isMainFrame
        origin = Origin.canonical(scheme: scheme, host: host, port: port)
    }

    @MainActor
    init(_ frame: WKFrameInfo) {
        let origin = frame.securityOrigin
        self.init(isMainFrame: frame.isMainFrame, scheme: origin.protocol, host: origin.host, port: origin.port)
    }
}

/// The `ble` message handler the polyfill posts to. Only the main frame of
/// the configured server origin reaches the bridge; anything else gets a
/// `SecurityError` reply and never touches it.
@MainActor
final class BridgeMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "ble"
    static let rejected = BridgeError(.securityError, "Bluetooth is only available to the PigRider server's page.")

    /// The configured server's canonical origin; nil while none is set.
    var origin: String?
    private let bridge: any BridgeCallHandling

    init(bridge: any BridgeCallHandling, origin: String?) {
        self.bridge = bridge
        self.origin = origin
    }

    /// Checks the source, decodes the body and hands the call to the bridge.
    /// `reply` runs exactly once.
    func receive(_ body: Any, from source: MessageSource, reply: @escaping @MainActor (BridgeReply) -> Void) {
        guard source.isMainFrame, let origin, source.origin == origin else {
            reply(.failure(Self.rejected))
            return
        }
        switch BridgeCall.decode(body) {
        case .failure(let error): reply(.failure(error))
        case .success(let call): bridge.handle(call, origin: origin, reply: reply)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        receive(message.body, from: MessageSource(message.frameInfo)) { replyHandler($0.jsonObject, nil) }
    }
}
