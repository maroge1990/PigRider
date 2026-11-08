import Foundation
import WebKit

/// Runs a function body with arguments in the page's main frame and world.
@MainActor
protocol PageScriptRunning: AnyObject {
    func runPageScript(_ body: String, arguments: [String: Any])
}

extension WKWebView: PageScriptRunning {
    func runPageScript(_ body: String, arguments: [String: Any]) {
        // Called synchronously per event: WebKit runs the scripts in call order.
        callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }
}

/// Sends bridge events to the page's polyfill, one script call per event, in
/// the order the bridge emits them. Without a page the events are dropped.
@MainActor
final class PageEventSink: EventSink {
    static let script = "globalThis.__pigriderBle.dispatch(e)"

    weak var page: (any PageScriptRunning)?

    init(page: (any PageScriptRunning)? = nil) {
        self.page = page
    }

    func send(_ event: BridgeEvent) {
        page?.runPageScript(Self.script, arguments: ["e": event.jsonObject])
    }
}
