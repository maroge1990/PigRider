import Foundation
@testable import PigRider

/// Loads `apple/web/test/fixtures/protocol.json`, which is bundled into the
/// test target. Both the polyfill's and the Swift tests use it.
enum ProtocolFixture {
    struct Missing: Error {}

    private final class BundleToken {}

    static func load() throws -> [String: Any] {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "protocol", withExtension: "json") else {
            throw Missing()
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Missing() }
        return root
    }

    static func entries(_ section: String) throws -> [[String: Any]] {
        guard let list = try load()[section] as? [[String: Any]] else { throw Missing() }
        return list
    }

    /// The fixture entry called `name` in `section`.
    static func entry(_ section: String, named name: String) throws -> [String: Any] {
        guard let entry = try entries(section).first(where: { $0["name"] as? String == name }) else { throw Missing() }
        return entry
    }

    /// Compares two JSON-like values structurally (as JSON would).
    static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        guard let da = try? JSONSerialization.data(withJSONObject: ["v": a], options: [.sortedKeys]),
              let db = try? JSONSerialization.data(withJSONObject: ["v": b], options: [.sortedKeys]) else { return false }
        return da == db
    }
}

let kickrID = UUID(uuidString: "5F1E0C2A-7B3D-4E59-9A61-2C8D4B7E9F10")!

func uuid(_ short: String) -> BluetoothUUID {
    BluetoothUUID(normalizing: short)!
}
