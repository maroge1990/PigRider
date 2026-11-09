import Foundation
import Testing

/// Which iPads the app installs on.
struct PlatformTests {
    /// iPadOS 17 and later. Raising this drops iPads that cannot update past 17,
    /// so it only changes on Mark's say (apple/AGENTS.md, Building).
    @Test func runsOnIPadOS17AndLater() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "MinimumOSVersion") as? String == "17.0")
    }

    @Test func isAnIPadApp() throws {
        let families = try #require(Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int])
        #expect(families == [2])
    }
}
