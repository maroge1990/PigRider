import Testing
import UIKit
@testable import PigRider

/// The app's real Copy / Cancel alert: it answers exactly once, however it ends.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
final class CopyPromptTests {
    let window: UIWindow
    let root = UIViewController()
    let prompt = CopyPrompt()
    var copied: [String] = []
    var answers: [Bool] = []

    init() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        prompt.animates = false
        prompt.copy = { [unowned self] in copied.append($0) }
    }

    func ask(on presenter: UIViewController?) {
        prompt.presenter = { presenter }
        prompt.ask("report") { [unowned self] in answers.append($0) }
    }

    /// Lets UIKit finish presenting or dismissing, and what that queues on the main queue run.
    func mainQueueTurns(_ count: Int = 3) async {
        for _ in 0..<count {
            await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { turn.resume() }
            }
        }
    }

    /// Main-queue turns until UIKit reaches `state` (at most 500 turns, no timers), then a few more.
    func settle(until state: () -> Bool) async {
        for _ in 0..<500 where !state() { await mainQueueTurns(1) }
        #expect(state())
        await mainQueueTurns()
    }

    var nothingPresented: Bool { root.presentedViewController == nil }
    var alertShown: Bool {
        var top = root.presentedViewController
        while let next = top?.presentedViewController { top = next }
        return top is UIAlertController && !(top?.isBeingPresented ?? true)
    }

    @Test func noPresenterMeansNoCopy() async {
        ask(on: nil)
        #expect(answers == [false])
        #expect(copied.isEmpty)
    }

    @Test func copyCopiesAndAnswersOnce() async {
        ask(on: root)
        await settle { alertShown }
        #expect(answers.isEmpty)
        prompt.choose(copy: true)
        root.dismiss(animated: false)  // as UIKit does around the button's handler
        await settle { nothingPresented }
        #expect(answers == [true])
        #expect(copied == ["report"])
    }

    @Test func cancelAnswersNoAndCopiesNothing() async {
        ask(on: root)
        await settle { alertShown }
        prompt.choose(copy: false)
        root.dismiss(animated: false)
        await settle { nothingPresented }
        #expect(answers == [false])
        #expect(copied.isEmpty)
    }

    /// E.g. Bluetooth turned off while the prompt sat on the device chooser,
    /// which the bridge then dismisses, alert and all.
    @Test func aPromptClosedWithoutAnAnswerCountsAsCancel() async {
        let chooser = UIViewController()
        chooser.modalPresentationStyle = .overFullScreen  // a sheet never settles in the test host's window
        root.present(chooser, animated: false)
        await settle { root.presentedViewController === chooser && !chooser.isBeingPresented }
        ask(on: chooser)
        await settle { alertShown }
        #expect(answers.isEmpty)
        root.dismiss(animated: false)
        await settle { nothingPresented }
        #expect(answers == [false])
        #expect(copied.isEmpty)
    }

    @Test func cancelClosesThePromptAndAnswersNo() async {
        ask(on: root)
        await settle { alertShown }
        prompt.cancel()
        #expect(answers == [false])
        await settle { nothingPresented }
        prompt.cancel()
        #expect(answers == [false])
    }

    /// UIKit refuses to present from a view controller outside any window.
    @Test func aPromptThatCannotBeShownAnswersNo() async {
        ask(on: UIViewController())
        #expect(answers == [false])
    }
}
