import Foundation
import Testing
@testable import PigRider

@MainActor
final class RecordingBridge: BridgeCallHandling {
    var calls: [(call: BridgeCall, origin: String)] = []
    var answer: BridgeReply = .success(.devices([]))

    func handle(_ call: BridgeCall, origin: String, reply: @escaping @MainActor (BridgeReply) -> Void) {
        calls.append((call, origin))
        reply(answer)
    }
}

/// Every message is checked for main frame and server origin before the bridge sees it.
@MainActor
struct BridgeMessageHandlerTests {
    static let origin = "https://ride.example.com"
    let bridge = RecordingBridge()
    let handler: BridgeMessageHandler

    init() {
        handler = BridgeMessageHandler(bridge: bridge, origin: Self.origin)
    }

    @discardableResult
    func send(_ body: Any = ["op": "getDevices"], mainFrame: Bool = true, scheme: String = "https",
              host: String = "ride.example.com", port: Int = 0) -> Replies {
        let replies = Replies()
        let source = MessageSource(isMainFrame: mainFrame, scheme: scheme, host: host, port: port)
        handler.receive(body, from: source) { replies.record($0) }
        return replies
    }

    @Test func aMainFrameCallFromTheServerReachesTheBridge() {
        let replies = send()
        #expect(bridge.calls.map(\.call) == [.getDevices])
        #expect(bridge.calls.map(\.origin) == [Self.origin])
        #expect(replies.single == .success(.devices([])))
    }

    @Test func theOriginIsComparedCanonically() {
        send(host: "RIDE.example.com", port: 443)
        #expect(bridge.calls.count == 1)
    }

    @Test func aSubframeOfTheServerIsRejected() {
        let replies = send(mainFrame: false)
        #expect(replies.error == BridgeMessageHandler.rejected)
        #expect(replies.errorName == .securityError)
        #expect(bridge.calls.isEmpty)
    }

    @Test func anotherOriginIsRejected() {
        #expect(send(host: "evil.example.com").errorName == .securityError)
        #expect(send(port: 8443).errorName == .securityError)
        #expect(send(scheme: "http").errorName == .securityError)
        #expect(bridge.calls.isEmpty)
    }

    @Test func everythingIsRejectedWhileNoServerIsSet() {
        handler.origin = nil
        #expect(send().errorName == .securityError)
        #expect(bridge.calls.isEmpty)
    }

    @Test func aMalformedCallIsAnsweredWithoutTheBridge() {
        #expect(send(["op": "connect"]).errorName == .dataError)
        #expect(send(["op": "readValue"]).errorName == .notSupportedError)
        #expect(bridge.calls.isEmpty)
    }

    @Test func aRejectedCallFromAnotherOriginIsNotDecoded() {
        #expect(send(["op": "readValue"], host: "evil.example.com").errorName == .securityError)
    }
}
