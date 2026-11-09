import Foundation

/// "version (build, commit)" for the settings screen. Build numbers are upload
/// timestamps, so the commit is what ties an installed app to the source.
enum AppVersion {
    static func label(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let value = { (key: String) in (info?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?" }
        return "\(value("CFBundleShortVersionString")) (\(value("CFBundleVersion")), \(value("PigRiderCommit")))"
    }
}
