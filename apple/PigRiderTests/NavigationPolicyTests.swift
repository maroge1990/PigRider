import Foundation
import Testing
@testable import PigRider

struct NavigationPolicyTests {
    let policy = NavigationPolicy(serverOrigin: "https://ride.example.com")

    func decide(_ string: String) -> NavigationPolicy.Decision {
        policy.decision(for: URL(string: string)!)
    }

    @Test func theServerLoadsInApp() {
        #expect(decide("https://ride.example.com/") == .loadInApp)
        #expect(decide("https://RIDE.example.com:443/strava/callback?code=1") == .loadInApp)
    }

    @Test func stravaLoadsInApp() {
        #expect(decide("https://www.strava.com/oauth/authorize?client_id=1") == .loadInApp)
    }

    @Test(arguments: [
        "http://ride.example.com/", "https://ride.example.com:8443/", "https://strava.com/", "http://www.strava.com/",
        "https://intervals.icu/", "mailto:a@b.c", "https://evil.example.com/?https://ride.example.com",
    ])
    func everythingElseOpensExternally(_ url: String) {
        #expect(decide(url) == .openExternally)
    }

    @Test func blankAndBlobsOfTheServerStayInApp() {
        #expect(decide("about:blank") == .loadInApp)
        #expect(decide("blob:https://ride.example.com/5c1e") == .loadInApp)
        #expect(decide("blob:https://evil.example.com/5c1e") == .openExternally)
    }

    @Test func withoutAServerOnlyStravaIsInApp() {
        let none = NavigationPolicy(serverOrigin: nil)
        #expect(none.decision(for: URL(string: "https://ride.example.com/")!) == .openExternally)
        #expect(none.decision(for: URL(string: "https://www.strava.com/")!) == .loadInApp)
    }
}
