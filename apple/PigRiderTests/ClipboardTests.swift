import Foundation
import Testing
@testable import PigRider

/// `copyText`: the page's `navigator.clipboard.writeText` over plain HTTP.
/// The page can't prove a tap to the app, so the rider confirms every copy.
@MainActor
struct ClipboardTests {
    let h = BridgeHarness()
    let report = "OpenRadlr device diagnostics"

    @Test func nothingIsCopiedUntilTheRiderTapsCopy() {
        let replies = h.call(.copyText(text: report))
        #expect(h.prompts.asked == [report])
        #expect(h.prompts.copied.isEmpty)
        #expect(replies.all.isEmpty)
        h.prompts.answer(true)
        #expect(h.prompts.copied == [report])
        #expect(replies.single == .success(.none))
    }

    @Test func cancelCopiesNothingAndRejects() {
        let replies = h.call(.copyText(text: report))
        h.prompts.answer(false)
        #expect(h.prompts.copied.isEmpty)
        #expect(replies.errorName == .notAllowedError)
    }

    /// A page can't stack prompts: one waits for the rider at a time.
    @Test func aSecondCopyWhileThePromptIsOpenIsRefused() {
        let first = h.call(.copyText(text: report))
        let second = h.call(.copyText(text: "replacement"))
        #expect(second.errorName == .notAllowedError)
        #expect(h.prompts.asked == [report])
        h.prompts.answer(true)
        #expect(first.single == .success(.none))
        let third = h.call(.copyText(text: report))
        #expect(h.prompts.asked.count == 2)
        h.prompts.answer(true)
        #expect(third.single == .success(.none))
    }

    @Test func thePromptShowsTheFirstLineAndHowManyFollow() {
        #expect(CopyPrompt.preview("OpenRadlr device diagnostics\nBuild: 1\nUser agent: x") ==
                "“OpenRadlr device diagnostics” and 2 more lines")
        #expect(CopyPrompt.preview("one line") == "“one line”")
        #expect(CopyPrompt.preview("a\nb") == "“a” and 1 more line")
        #expect(CopyPrompt.preview(String(repeating: "x", count: 81)) == "“\(String(repeating: "x", count: 80))…”")
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
