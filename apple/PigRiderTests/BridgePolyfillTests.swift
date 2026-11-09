import Foundation
import Testing
@testable import PigRider

/// The user script: the bundled polyfill plus the line that installs it.
struct BridgePolyfillTests {
    let polyfill = BridgePolyfill(source: "function installPigriderBluetooth() {}", version: 7)

    @Test func theScriptStartsWithThePolyfill() {
        #expect(polyfill.userScriptSource(origin: "https://ride.example.com").hasPrefix(polyfill.source + "\n"))
    }

    @Test func theScriptInstallsForTheOriginAndVersion() {
        let source = polyfill.userScriptSource(origin: "https://ride.example.com:8443")
        #expect(source.hasSuffix(
            "\ninstallPigriderBluetooth(globalThis, { origin: \"https://ride.example.com:8443\", version: 7 });\n"))
    }

    @Test func theOriginIsAJSONStringLiteral() {
        let source = polyfill.userScriptSource(origin: "https://a\"b\\c\n")
        #expect(source.contains("origin: \"https://a\\\"b\\\\c\\n\", version: 7"))
    }

    @Test func theBundledPolyfillAndVersionLoad() throws {
        let bundled = try BridgePolyfill.bundled()
        #expect(bundled.source.contains("function installPigriderBluetooth(target"))
        #expect(bundled.version == 1)
    }
}
