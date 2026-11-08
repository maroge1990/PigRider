import Foundation

/// A device the user picked for an origin, and the services it may use there
/// (the request's filter services plus `optionalServices`).
struct DeviceGrant: Codable, Equatable, Sendable {
    let id: UUID
    var name: String?
    var services: [BluetoothUUID]
}

/// Persisted grants keyed by (canonical origin, device id). Every bridge call
/// checks the grant of the calling origin, as Chrome does.
@MainActor
final class GrantStore {
    static let key = "bluetoothGrants"
    private let store: any KeyValueStoring
    private var grants: [String: [DeviceGrant]]

    init(store: any KeyValueStoring) {
        self.store = store
        grants = store.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: [DeviceGrant]].self, from: $0) } ?? [:]
    }

    func grant(origin: String, id: UUID) -> DeviceGrant? {
        guard let origin = Origin.canonical(origin) else { return nil }
        return grants[origin]?.first { $0.id == id }
    }

    /// Granted devices of an origin, oldest grant first.
    func devices(for origin: String) -> [DeviceGrant] {
        Origin.canonical(origin).flatMap { grants[$0] } ?? []
    }

    /// Adds a grant, or widens an existing one by `services` and updates its name.
    func grant(origin: String, id: UUID, name: String?, services: [BluetoothUUID]) {
        guard let origin = Origin.canonical(origin) else { return }
        var list = grants[origin] ?? []
        if let index = list.firstIndex(where: { $0.id == id }) {
            list[index].name = name ?? list[index].name
            for service in services where !list[index].services.contains(service) {
                list[index].services.append(service)
            }
        } else {
            var unique: [BluetoothUUID] = []
            for service in services where !unique.contains(service) { unique.append(service) }
            list.append(DeviceGrant(id: id, name: name, services: unique))
        }
        grants[origin] = list
        save()
    }

    func revoke(origin: String, id: UUID) {
        guard let origin = Origin.canonical(origin) else { return }
        grants[origin]?.removeAll { $0.id == id }
        if grants[origin]?.isEmpty == true { grants[origin] = nil }
        save()
    }

    private func save() {
        store.set(try? JSONEncoder().encode(grants), forKey: Self.key)
    }
}
