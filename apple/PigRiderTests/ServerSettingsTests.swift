import Foundation
import Testing
@testable import PigRider

struct OriginTests {
    @Test func canonicalOriginLowercasesAndDropsDefaultPortAndPath() {
        #expect(Origin.canonical("HTTPS://Ride.Example.COM:443/app?x=1") == "https://ride.example.com")
        #expect(Origin.canonical("https://ride.example.com:8443/") == "https://ride.example.com:8443")
        #expect(Origin.canonical("http://ride.example.com:80") == "http://ride.example.com")
    }

    @Test func nonWebURLsHaveNoOrigin() {
        #expect(Origin.canonical("file:///tmp/x") == nil)
        #expect(Origin.canonical("about:blank") == nil)
    }

    @Test func originFromComponents() {
        #expect(Origin.canonical(scheme: "https", host: "Ride.example.com", port: 0) == "https://ride.example.com")
        #expect(Origin.canonical(scheme: "https", host: "ride.example.com", port: 8443) == "https://ride.example.com:8443")
    }
}

@MainActor
struct ServerSettingsTests {
    let store = InMemoryStore()

    @Test func noServerAtFirst() {
        let settings = ServerSettings(store: store)
        #expect(settings.serverURL == nil)
        #expect(settings.origin == nil)
    }

    @Test func anHTTPSServerIsStoredWithItsCanonicalOrigin() throws {
        let settings = ServerSettings(store: store)
        try settings.setServer(" https://Ride.Example.com:443 ")
        #expect(settings.serverURL?.absoluteString == "https://ride.example.com/")
        #expect(settings.origin == "https://ride.example.com")
        #expect(ServerSettings(store: store).origin == "https://ride.example.com")
    }

    @Test func aBareHostMeansHTTPS() throws {
        let settings = ServerSettings(store: store)
        try settings.setServer("ride.example.com:8443")
        #expect(settings.serverURL?.absoluteString == "https://ride.example.com:8443/")
    }

    @Test func plainHTTPIsRefused() {
        let settings = ServerSettings(store: store)
        #expect(throws: ServerSettings.Failure.notHTTPS) { try settings.setServer("http://ride.example.com") }
        #expect(settings.serverURL == nil)
    }

    @Test(arguments: ["", "https://", "https://user:pw@ride.example.com", "ftp://ride.example.com"])
    func invalidInputIsRefused(_ input: String) {
        let settings = ServerSettings(store: store)
        #expect(throws: ServerSettings.Failure.self) { try settings.setServer(input) }
        #expect(settings.serverURL == nil)
    }

    @Test func aPathIsKeptButQueryAndFragmentAreDropped() throws {
        let settings = ServerSettings(store: store)
        try settings.setServer("https://ride.example.com/openradlr/?a=1#x")
        #expect(settings.serverURL?.absoluteString == "https://ride.example.com/openradlr/")
        #expect(settings.origin == "https://ride.example.com")
    }
}
