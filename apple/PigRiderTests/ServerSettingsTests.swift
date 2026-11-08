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

    @Test(arguments: [
        "ride.example.com", "8.8.8.8", "172.32.0.1", "192.169.0.1", "100.100.1.1", "11.0.0.1",
        "passyflix.lan", "x.local.example.com", "[2001:db8::1]", "[::ffff:192.168.1.1]",
        // Forms WebKit would read as a different (possibly public) IPv4 address.
        "010.0.0.1", "0x0a.0.0.1", "10.1", "167772161", "134744072", "0x8080808",
    ])
    func plainHTTPIsRefusedOutsideTheHomeNetwork(_ host: String) {
        let settings = ServerSettings(store: store)
        #expect(throws: ServerSettings.Failure.httpNotLocal) { try settings.setServer("http://\(host)") }
        #expect(settings.serverURL == nil)
    }

    @Test(arguments: [
        ("10.0.0.5", "http://10.0.0.5"), ("172.16.0.1", "http://172.16.0.1"),
        ("172.31.255.255", "http://172.31.255.255"), ("192.168.1.20", "http://192.168.1.20"),
        ("169.254.10.1", "http://169.254.10.1"), ("127.0.0.1", "http://127.0.0.1"),
        ("localhost", "http://localhost"), ("PassyFlix", "http://passyflix"),
        ("passyflix.local", "http://passyflix.local"), ("Mac-Mini.Local", "http://mac-mini.local"),
        ("[fd12:3456::1]", "http://[fd12:3456::1]"), ("[fe80::1]", "http://[fe80::1]"), ("[::1]", "http://[::1]"),
    ])
    func plainHTTPIsAcceptedOnTheHomeNetwork(_ host: String, _ origin: String) throws {
        let settings = ServerSettings(store: store)
        try settings.setServer("http://\(host):8080")
        #expect(settings.origin == "\(origin):8080")
        #expect(settings.serverURL?.absoluteString == "\(origin):8080/")
    }

    @Test func aBareHomeNetworkAddressMeansHTTP() throws {
        let settings = ServerSettings(store: store)
        try settings.setServer("192.168.1.20:8080")
        #expect(settings.serverURL?.absoluteString == "http://192.168.1.20:8080/")
        try settings.setServer("passyflix.local")
        #expect(settings.serverURL?.absoluteString == "http://passyflix.local/")
    }

    @Test func httpsStaysHTTPSOnTheHomeNetwork() throws {
        let settings = ServerSettings(store: store)
        try settings.setServer("https://192.168.1.20")
        #expect(settings.origin == "https://192.168.1.20")
    }

    @Test func theHTTPDefaultPortIsLeftOut() throws {
        let settings = ServerSettings(store: store)
        try settings.setServer("http://192.168.1.20:80")
        #expect(settings.serverURL?.absoluteString == "http://192.168.1.20/")
    }

    @Test func atsAllowsOnlyLocalNetworking() throws {
        let ats = try #require(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(Set(ats.keys) == ["NSAllowsLocalNetworking"])
        let reason = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        #expect(!(reason ?? "").isEmpty)
    }

    @Test(arguments: ["", "https://", "https://user:pw@ride.example.com", "http://user:pw@192.168.1.20", "ftp://ride.example.com"])
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
