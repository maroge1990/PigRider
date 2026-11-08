import Foundation
import Observation

/// The model behind the `requestDevice` chooser sheet: peripherals matching
/// the request's filters, updated live from the shared scan. The SwiftUI
/// sheet (T7) observes `devices` and reports the pick through
/// `ChooserPresenting`'s completion.
@MainActor
@Observable
final class DeviceChooser {
    struct Device: Identifiable, Equatable, Sendable {
        let id: UUID
        var name: String?
        var rssi: Int
    }

    let filters: [RequestFilter]
    private(set) var devices: [Device] = []

    init(filters: [RequestFilter]) {
        self.filters = filters
    }

    /// Adds or refreshes a sighting if it matches the filters.
    func record(_ ad: Advertisement) {
        guard filters.anyMatches(ad) else { return }
        if let index = devices.firstIndex(where: { $0.id == ad.id }) {
            devices[index].rssi = ad.rssi
            if let name = ad.name { devices[index].name = name }
        } else {
            devices.append(Device(id: ad.id, name: ad.name, rssi: ad.rssi))
        }
    }

    func device(_ id: UUID) -> Device? {
        devices.first { $0.id == id }
    }
}
