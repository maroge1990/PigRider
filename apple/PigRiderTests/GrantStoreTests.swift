import Foundation
import Testing
@testable import PigRider

@MainActor
struct GrantStoreTests {
    let store = InMemoryStore()
    let origin = "https://ride.example.com"
    let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func aGrantIsKeyedByOriginAndDevice() {
        let grants = GrantStore(store: store)
        grants.grant(origin: origin, id: kickrID, name: "KICKR", services: [uuid("1826")])
        #expect(grants.grant(origin: origin, id: kickrID)?.services == [uuid("1826")])
        #expect(grants.grant(origin: "https://other.example.com", id: kickrID) == nil)
        #expect(grants.grant(origin: origin, id: other) == nil)
    }

    @Test func originsAreComparedCanonically() {
        let grants = GrantStore(store: store)
        grants.grant(origin: "HTTPS://Ride.Example.com:443", id: kickrID, name: "KICKR", services: [])
        #expect(grants.grant(origin: origin, id: kickrID) != nil)
    }

    @Test func grantsPersistInTheStore() {
        GrantStore(store: store).grant(origin: origin, id: kickrID, name: "KICKR", services: [uuid("1826")])
        let reloaded = GrantStore(store: store)
        #expect(reloaded.devices(for: origin) == [DeviceGrant(id: kickrID, name: "KICKR", services: [uuid("1826")])])
    }

    @Test func aRepeatedGrantAddsServicesAndKeepsOrder() {
        let grants = GrantStore(store: store)
        grants.grant(origin: origin, id: kickrID, name: "KICKR", services: [uuid("1826")])
        grants.grant(origin: origin, id: other, name: "Polar", services: [uuid("180d")])
        grants.grant(origin: origin, id: kickrID, name: "KICKR CORE", services: [uuid("1818")])
        #expect(grants.devices(for: origin).map(\.id) == [kickrID, other])
        #expect(grants.grant(origin: origin, id: kickrID)?.services == [uuid("1826"), uuid("1818")])
        #expect(grants.grant(origin: origin, id: kickrID)?.name == "KICKR CORE")
    }

    @Test func revokeRemovesOnlyThatOriginsGrant() {
        let grants = GrantStore(store: store)
        grants.grant(origin: origin, id: kickrID, name: "KICKR", services: [])
        grants.grant(origin: "https://other.example.com", id: kickrID, name: "KICKR", services: [])
        grants.revoke(origin: origin, id: kickrID)
        #expect(grants.grant(origin: origin, id: kickrID) == nil)
        #expect(GrantStore(store: store).grant(origin: "https://other.example.com", id: kickrID) != nil)
    }

    @Test func anUnparsableOriginHasNoGrants() {
        let grants = GrantStore(store: store)
        grants.grant(origin: "not an origin", id: kickrID, name: "KICKR", services: [])
        #expect(grants.devices(for: "not an origin").isEmpty)
    }
}
