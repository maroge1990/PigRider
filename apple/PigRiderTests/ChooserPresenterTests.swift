import Foundation
import Testing
@testable import PigRider

/// The app's `ChooserPresenting`: the state the chooser sheet shows.
@MainActor
struct ChooserPresenterTests {
    let presenter = ChooserPresenter()
    let chooser = DeviceChooser(filters: [RequestFilter(namePrefix: "KICKR")])
    let picks = PickLog()

    @MainActor
    final class PickLog {
        var picks: [UUID?] = []
    }

    func present() {
        let picks = self.picks
        presenter.present(chooser) { picks.picks.append($0) }
    }

    @Test func presentingShowsTheChooser() {
        present()
        #expect(presenter.request?.chooser === chooser)
    }

    @Test func aPickClosesTheSheetAndCompletesOnce() {
        present()
        presenter.pick(kickrID)
        presenter.pick(nil)
        #expect(picks.picks == [kickrID])
        #expect(presenter.request == nil)
    }

    @Test func cancelCompletesWithNil() {
        present()
        presenter.pick(nil)
        #expect(picks.picks == [nil])
    }

    @Test func aDismissFromTheBridgeClosesWithoutCompleting() {
        present()
        presenter.dismiss(chooser)
        #expect(presenter.request == nil)
        #expect(picks.picks.isEmpty)
    }

    @Test func theSheetClosingOnItsOwnCancelsItsRequestOnly() {
        present()
        let first = presenter.request!.id
        presenter.dismiss(chooser)
        present()
        presenter.sheetClosed(first)
        #expect(picks.picks.isEmpty)
        presenter.sheetClosed(presenter.request!.id)
        #expect(picks.picks == [nil])
    }
}
