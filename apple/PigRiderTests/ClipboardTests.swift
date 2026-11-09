import Foundation
import Testing
@testable import PigRider

/// `copyText`: the page's `navigator.clipboard.writeText` over plain HTTP.
@MainActor
struct ClipboardTests {
    let h = BridgeHarness()

    @Test func theTextGoesToTheClipboardAndTheReplyIsNull() {
        let replies = h.call(.copyText(text: "OpenRadlr device diagnostics"))
        #expect(h.copied.texts == ["OpenRadlr device diagnostics"])
        #expect(replies.single == .success(.none))
    }

    /// A device report is far longer than the 248-byte limit for names and ids.
    @Test func aLongReportDecodes() {
        let report = String(repeating: "[12.3s] INFO zwift 37 08 00 10 01\n", count: 3000)
        #expect(BridgeCall.decode(["op": "copyText", "text": report]) == .success(.copyText(text: report)))
    }

    @Test func textOverTheLimitIsRefused() {
        let text = String(repeating: "x", count: BridgeCall.maxTextBytes + 1)
        guard case .failure(let error) = BridgeCall.decode(["op": "copyText", "text": text]) else {
            Issue.record("decoded")
            return
        }
        #expect(error.name == .dataError)
    }

    @Test func textAtTheLimitDecodes() {
        let text = String(repeating: "x", count: BridgeCall.maxTextBytes)
        #expect(BridgeCall.decode(["op": "copyText", "text": text]) == .success(.copyText(text: text)))
    }
}
