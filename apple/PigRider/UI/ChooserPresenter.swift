import Foundation
import Observation

/// The app's `ChooserPresenting`: holds the open `requestDevice` chooser for
/// the SwiftUI sheet. The completion runs at most once per request.
@MainActor
@Observable
final class ChooserPresenter: ChooserPresenting {
    struct Request: Identifiable {
        let id = UUID()
        let chooser: DeviceChooser
        fileprivate let completion: @MainActor (UUID?) -> Void
    }

    private(set) var request: Request?

    func present(_ chooser: DeviceChooser, completion: @escaping @MainActor (UUID?) -> Void) {
        request = Request(chooser: chooser, completion: completion)
    }

    func dismiss(_ chooser: DeviceChooser) {
        if request?.chooser === chooser { request = nil }
    }

    /// The user picked a device, or cancelled (`nil`).
    func pick(_ id: UUID?) {
        guard let request else { return }
        self.request = nil
        request.completion(id)
    }

    /// The sheet that showed `requestID` went away; if that request is still
    /// open (the sheet was not closed by `pick` or `dismiss`), it is cancelled.
    func sheetClosed(_ requestID: UUID) {
        if request?.id == requestID { pick(nil) }
    }
}
