import Foundation
@testable import PigRider

final class InMemoryStore: KeyValueStoring {
    var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
