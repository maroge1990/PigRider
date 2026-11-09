import SwiftUI
import WebKit

/// Hosts the shell's web view, with a three-finger long press that opens settings.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    let onThreeFingerLongPress: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: onThreeFingerLongPress)
    }

    func makeUIView(context: Context) -> WKWebView {
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.numberOfTouchesRequired = 3
        press.minimumPressDuration = 1
        press.cancelsTouchesInView = false
        press.delegate = context.coordinator
        webView.addGestureRecognizer(press)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.action = onThreeFingerLongPress
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func pressed(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { action() }
        }

        /// The page keeps getting its touches while the press is recognised.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
