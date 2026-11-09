import Foundation
import Testing
@testable import PigRider

struct RequestFilterTests {
    let ftms = uuid("1826")
    let power = uuid("1818")

    func ad(name: String? = nil, services: [BluetoothUUID] = [], companies: [UInt16] = []) -> Advertisement {
        Advertisement(id: kickrID, name: name, services: Set(services), manufacturerCompanyIdentifiers: Set(companies), rssi: -60)
    }

    @Test func servicesMatchWhenAllAreAdvertised() {
        let filter = RequestFilter(services: [ftms, power])
        #expect(filter.matches(ad(services: [power, ftms, uuid("180a")])))
        #expect(!filter.matches(ad(services: [ftms])))
    }

    @Test func nameMatchesExactly() {
        let filter = RequestFilter(name: "KICKR CORE 1234")
        #expect(filter.matches(ad(name: "KICKR CORE 1234")))
        #expect(!filter.matches(ad(name: "KICKR CORE 12345")))
        #expect(!filter.matches(ad()))
    }

    @Test func namePrefixMatchesTheStart() {
        let filter = RequestFilter(namePrefix: "Zwift")
        #expect(filter.matches(ad(name: "Zwift Click")))
        #expect(!filter.matches(ad(name: "My Zwift")))
        #expect(!filter.matches(ad()))
    }

    @Test func manufacturerDataMatchesByCompanyIdentifier() {
        let filter = RequestFilter(manufacturerCompanyIdentifiers: [0x094A])
        #expect(filter.matches(ad(companies: [0x094A])))
        #expect(!filter.matches(ad(companies: [0x004C])))
    }

    @Test func everyPresentKeyMustMatch() {
        let filter = RequestFilter(services: [ftms], namePrefix: "KICKR")
        #expect(filter.matches(ad(name: "KICKR CORE", services: [ftms])))
        #expect(!filter.matches(ad(name: "Elite", services: [ftms])))
        #expect(!filter.matches(ad(name: "KICKR CORE")))
    }

    @Test func aRequestMatchesWhenAnyFilterMatches() {
        let filters = [RequestFilter(manufacturerCompanyIdentifiers: [0x094A]), RequestFilter(namePrefix: "Zwift")]
        #expect(filters.anyMatches(ad(name: "Zwift Play")))
        #expect(filters.anyMatches(ad(companies: [0x094A])))
        #expect(!filters.anyMatches(ad(name: "Polar H10")))
    }
}
