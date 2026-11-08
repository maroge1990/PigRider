import Foundation
import Testing
@testable import PigRider

/// What App Store Connect needs from the app bundle for a TestFlight upload.
struct ReleaseConfigTests {
    @Test func theAppHasAnIcon() throws {
        let icons = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons~ipad") as? [String: Any])
        let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(primary["CFBundleIconName"] as? String == "AppIcon")
    }

    /// Only standard HTTPS (or plain HTTP at home): exempt, so no export question per upload.
    @Test func exportComplianceIsAnswered() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool == false)
    }

    @Test func versionsComeFromBuildSettings() throws {
        let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let build = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        #expect(version.split(separator: ".").count == 3)
        #expect(Int(build) != nil)
    }

    /// Build numbers are timestamps, so the bundle names its commit (`dev` for unsigned builds).
    @Test func theBundleNamesItsCommit() throws {
        let commit = try #require(Bundle.main.object(forInfoDictionaryKey: "PigRiderCommit") as? String)
        #expect(!commit.isEmpty)
    }

    @Test func settingsShowVersionBuildAndCommit() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1794174000",
                                   "PigRiderCommit": "225e0cd"]
        #expect(AppVersion.label(info: info) == "0.1.0 (1794174000, 225e0cd)")
        #expect(AppVersion.label(info: [:]) == "? (?, ?)")
    }
}
