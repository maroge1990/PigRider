import Foundation

/// The slice of `UserDefaults` the app persists through, so tests use a fake.
protocol KeyValueStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStoring {}
