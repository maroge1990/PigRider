import Foundation

/// One sighting of a peripheral during a scan, reduced to what filters and
/// watches need.
struct Advertisement: Equatable, Sendable {
    let id: UUID
    /// The advertised local name, else the peripheral's GAP name.
    let name: String?
    let services: Set<BluetoothUUID>
    let manufacturerCompanyIdentifiers: Set<UInt16>
    let rssi: Int
}

/// A `requestDevice` filter after the polyfill's normalisation. Every key that
/// is present must match.
struct RequestFilter: Equatable, Sendable {
    var services: [BluetoothUUID]?
    var name: String?
    var namePrefix: String?
    var manufacturerCompanyIdentifiers: [UInt16]?

    init(services: [BluetoothUUID]? = nil, name: String? = nil, namePrefix: String? = nil,
         manufacturerCompanyIdentifiers: [UInt16]? = nil) {
        self.services = services
        self.name = name
        self.namePrefix = namePrefix
        self.manufacturerCompanyIdentifiers = manufacturerCompanyIdentifiers
    }

    func matches(_ ad: Advertisement) -> Bool {
        if let services, !services.allSatisfy(ad.services.contains) { return false }
        if let name, ad.name != name { return false }
        if let namePrefix, !(ad.name?.hasPrefix(namePrefix) ?? false) { return false }
        if let ids = manufacturerCompanyIdentifiers, !ids.allSatisfy(ad.manufacturerCompanyIdentifiers.contains) {
            return false
        }
        return true
    }
}

extension Array where Element == RequestFilter {
    /// A request matches a sighting when any of its filters does.
    func anyMatches(_ ad: Advertisement) -> Bool {
        contains { $0.matches(ad) }
    }
}
