import Foundation

/// Which navigations stay in the web view: the server's origin and Strava's
/// OAuth pages. Everything else opens externally (Safari or the owning app).
struct NavigationPolicy: Sendable {
    enum Decision: Equatable, Sendable {
        case loadInApp
        case openExternally
    }

    static let stravaOrigin = "https://www.strava.com"

    let serverOrigin: String?

    func decision(for url: URL) -> Decision {
        switch url.scheme?.lowercased() {
        case "about":
            // `about:blank`/`about:srcdoc` are documents of the current page, not navigations away.
            return ["about:blank", "about:srcdoc"].contains(url.absoluteString.lowercased()) ? .loadInApp : .openExternally
        case "blob":
            // `blob:https://host/uuid` belongs to the origin after the prefix (e.g. a ride file download).
            let inner = String(url.absoluteString.dropFirst("blob:".count))
            return isInApp(Origin.canonical(inner)) ? .loadInApp : .openExternally
        default:
            return isInApp(Origin.canonical(url)) ? .loadInApp : .openExternally
        }
    }

    private func isInApp(_ origin: String?) -> Bool {
        guard let origin else { return false }
        return origin == Self.stravaOrigin || origin == serverOrigin
    }
}
