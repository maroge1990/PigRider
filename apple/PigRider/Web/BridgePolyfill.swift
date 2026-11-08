import Foundation
import WebKit

/// The `navigator.bluetooth` polyfill (`apple/web/bluetooth-bridge.js`) and the
/// bridge version, both bundled as resources, and the user script built from them.
struct BridgePolyfill: Sendable {
    struct MissingResource: Error {
        let name: String
    }

    let source: String
    let version: Int

    static func bundled(in bundle: Bundle = .main) throws -> BridgePolyfill {
        guard let scriptURL = bundle.url(forResource: "bluetooth-bridge", withExtension: "js") else {
            throw MissingResource(name: "bluetooth-bridge.js")
        }
        guard let versionURL = bundle.url(forResource: "BRIDGE_VERSION", withExtension: nil),
              let version = Int(try String(contentsOf: versionURL, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MissingResource(name: "BRIDGE_VERSION")
        }
        return BridgePolyfill(source: try String(contentsOf: scriptURL, encoding: .utf8), version: version)
    }

    /// The polyfill plus the line that installs it for `origin`. The polyfill
    /// itself checks `location.origin`, so other pages get no `navigator.bluetooth`.
    func userScriptSource(origin: String) -> String {
        "\(source)\ninstallPigriderBluetooth(globalThis, { origin: \(Self.jsonString(origin)), version: \(version) });\n"
    }

    /// Runs at document start, in the main frame only, in the page's own world
    /// (upstream's code reads `navigator.bluetooth` there). WebKit objects belong to the main actor.
    @MainActor
    func userScript(origin: String) -> WKUserScript {
        WKUserScript(source: userScriptSource(origin: origin), injectionTime: .atDocumentStart,
                     forMainFrameOnly: true, in: .page)
    }

    /// `text` as a JSON string literal, which is also a valid JS string literal.
    static func jsonString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Encoding a String cannot fail; `undefined` makes the polyfill skip installing.
        return (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "undefined"
    }
}

/// Builds the web view configuration that connects pages to the bridge.
@MainActor
enum BridgeWebConfiguration {
    /// A configuration whose pages from `origin` get `navigator.bluetooth`,
    /// with calls going to `handler`. No origin: no polyfill at all.
    static func make(polyfill: BridgePolyfill, origin: String?, handler: BridgeMessageHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addScriptMessageHandler(handler, contentWorld: .page, name: BridgeMessageHandler.name)
        configuration.userContentController = controller
        setOrigin(origin, polyfill: polyfill, handler: handler, in: controller)
        return configuration
    }

    /// Points the polyfill and the handler at a new server origin. Takes effect
    /// for messages at once and for the user script from the next document on.
    static func setOrigin(_ origin: String?, polyfill: BridgePolyfill, handler: BridgeMessageHandler,
                          in controller: WKUserContentController) {
        handler.origin = origin
        controller.removeAllUserScripts()
        if let origin { controller.addUserScript(polyfill.userScript(origin: origin)) }
    }
}
