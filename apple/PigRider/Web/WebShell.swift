import Observation
import UIKit
import WebKit

/// What the shell shows on top of the page.
@MainActor
@Observable
final class ShellStatus {
    /// The last Web Bluetooth member the page wanted and the bridge lacks.
    var unsupportedMember: String?
    /// Why the server's page could not be loaded; nil once a page commits.
    var loadFailure: String?
}

/// What the bridge needs to ask the rider before a copy. `ask` answers exactly
/// once (true: copied); `cancel` closes an open prompt, which then answers false.
@MainActor
protocol CopyPrompting: AnyObject {
    func ask(_ text: String, done: @escaping @MainActor (Bool) -> Void)
    func cancel()
}

/// The rider's Copy / Cancel alert for the page's `navigator.clipboard.writeText`
/// over plain HTTP: the page can't prove a tap to the app, so the rider confirms.
/// However the alert ends (a button, `cancel()`, or vanishing with the view it sat
/// on), it answers once; one that UIKit won't show answers false at once.
@MainActor
final class CopyPrompt: CopyPrompting {
    var presenter: @MainActor () -> UIViewController? = { nil }
    var copy: @MainActor (String) -> Void = { UIPasteboard.general.string = $0 }
    var animates = true
    private var open: (alert: UIAlertController, text: String, done: @MainActor (Bool) -> Void)?

    func ask(_ text: String, done: @escaping @MainActor (Bool) -> Void) {
        cancel()
        guard let presenter = presenter() else { return done(false) }
        let alert = CopyAlert(title: "Copy to the clipboard?", message: Self.preview(text), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.choose(copy: false) })
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { [weak self] _ in self?.choose(copy: true) })
        // An action's handler runs after the alert has disappeared: a turn later, an answer is already in.
        alert.onDisappear = { [weak self, weak alert] in
            DispatchQueue.main.async { if let alert { self?.finish(alert, copied: false) } }
        }
        open = (alert, text, done)
        presenter.present(alert, animated: animates)
        if alert.presentingViewController == nil { finish(alert, copied: false) }
    }

    func cancel() {
        guard let alert = open?.alert else { return }
        finish(alert, copied: false)
        alert.presentingViewController?.dismiss(animated: false)
    }

    /// What the alert's buttons do.
    func choose(copy: Bool) {
        if let alert = open?.alert { finish(alert, copied: copy) }
    }

    private func finish(_ alert: UIAlertController, copied: Bool) {
        guard let open, open.alert === alert else { return }
        self.open = nil
        if copied { copy(open.text) }
        open.done(copied)
    }

    /// The first line (up to 80 characters) and how many more follow, so the rider sees what is copied.
    static func preview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let first = lines.first.map(String.init) ?? ""
        let shown = first.count > 80 ? String(first.prefix(80)) + "…" : first
        switch lines.count - 1 {
        case 0: return "“\(shown)”"
        case 1: return "“\(shown)” and 1 more line"
        case let more: return "“\(shown)” and \(more) more lines"
        }
    }
}

private final class CopyAlert: UIAlertController {
    var onDisappear: (@MainActor () -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

/// The full-screen web view with the server's client, the Bluetooth bridge
/// wired in, and the document lifetime and navigation rules of the spec
/// ("The web view", "Document lifetime").
@MainActor
final class WebShell: NSObject {
    let webView: WKWebView
    let status: ShellStatus
    private let bridge: BluetoothBridge
    private let handler: BridgeMessageHandler
    private let polyfill: BridgePolyfill
    private let contentController: WKUserContentController
    private let openExternally: @MainActor (URL) -> Void
    private var policy = NavigationPolicy(serverOrigin: nil)
    private(set) var server: URL?

    init(polyfill: BridgePolyfill, grants: GrantStore, chooser: any ChooserPresenting,
         openExternally: @escaping @MainActor (URL) -> Void) {
        let status = ShellStatus()
        self.status = status
        let sink = PageEventSink()
        let copyPrompt = CopyPrompt()
        bridge = BluetoothBridge.live(grants: grants, events: sink, chooser: chooser,
                                      onUnsupported: { [weak status] in status?.unsupportedMember = $0 },
                                      copyPrompt: copyPrompt)
        handler = BridgeMessageHandler(bridge: bridge, origin: nil)
        let configuration = BridgeWebConfiguration.make(polyfill: polyfill, origin: nil, handler: handler)
        contentController = configuration.userContentController
        webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        sink.page = webView
        self.polyfill = polyfill
        self.openExternally = openExternally
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        copyPrompt.presenter = { [weak self] in self?.presenter }
    }

    /// Shows `server` (nil: nothing). A different server ends the current
    /// document's Bluetooth state; its grants stay with its origin.
    func show(server: URL?) {
        if self.server != nil, server != self.server { bridge.serverDidChange() }
        self.server = server
        let origin = server.flatMap(Origin.canonical)
        policy = NavigationPolicy(serverOrigin: origin)
        BridgeWebConfiguration.setOrigin(origin, polyfill: polyfill, handler: handler, in: contentController)
        status.loadFailure = nil
        if let server { webView.load(URLRequest(url: server)) }
    }

    func retry() {
        show(server: server)
    }

    /// The scene went to the background (not just inactive) or came back.
    func sceneDidEnterBackground() { bridge.enterBackground() }
    func sceneDidBecomeActive() { bridge.enterForeground() }

    /// The view controller to present native dialogs from.
    private var presenter: UIViewController? {
        var top = webView.window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

extension WebShell: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Subframes are the page's business; new windows go through `createWebViewWith`.
        guard navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        switch policy.decision(for: url) {
        case .loadInApp:
            decisionHandler(.allow)
        case .openExternally:
            decisionHandler(.cancel)
            openExternally(url)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new main-frame document (load, reload, Strava OAuth round trip).
        status.loadFailure = nil
        bridge.documentDidChange()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        bridge.documentDidChange()
        if webView.url != nil { webView.reload() } else if let server { webView.load(URLRequest(url: server)) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        reportLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        reportLoadFailure(error)
    }

    private func reportLoadFailure(_ error: any Error) {
        let error = error as NSError
        // A navigation replaced by another one, or cancelled by the policy above, is not a failure.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return }  // frame load interrupted by policy
        status.loadFailure = error.localizedDescription
    }
}

extension WebShell: WKUIDelegate {
    /// `target="_blank"` and `window.open`: never a second web view. They open
    /// in Safari, so a link on the ride summary does not end the ride page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { openExternally(url) }
        return nil
    }

    // Upstream uses `confirm()` (e.g. discarding an unfinished ride); without
    // these WebKit answers `false` and shows nothing.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        guard let presenter else { return completionHandler() }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let presenter else { return completionHandler(false) }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }
}
