import Foundation

/// Web origins in canonical form: `scheme://host[:port]`, lowercase, the
/// default port left out. Grants and navigation compare these strings.
enum Origin {
    static func canonical(_ url: URL) -> String? {
        canonical(scheme: url.scheme ?? "", host: url.host(percentEncoded: false) ?? "", port: url.port ?? 0)
    }

    static func canonical(_ text: String) -> String? {
        URL(string: text).flatMap(canonical)
    }

    /// `port` 0 (as `WKSecurityOrigin` reports it) means the scheme's default.
    static func canonical(scheme: String, host: String, port: Int) -> String? {
        let scheme = scheme.lowercased()
        let defaultPort: Int
        switch scheme {
        case "https": defaultPort = 443
        case "http": defaultPort = 80
        default: return nil
        }
        guard !host.isEmpty else { return nil }
        var host = host.lowercased()
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
        return port == 0 || port == defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
}

/// The self-hosted server the web view loads: HTTPS anywhere, or plain HTTP
/// on the home network (see `HomeNetwork`; ATS allows only that exception).
@MainActor
final class ServerSettings {
    enum Failure: Error, Equatable {
        case invalid
        case httpNotLocal
    }

    static let key = "serverURL"
    private let store: any KeyValueStoring

    init(store: any KeyValueStoring) {
        self.store = store
    }

    var serverURL: URL? {
        store.string(forKey: Self.key).flatMap { URL(string: $0) }
    }

    /// The canonical origin of `serverURL`; the bridge and navigation policy use it.
    var origin: String? {
        serverURL.flatMap(Origin.canonical)
    }

    @discardableResult
    func setServer(_ input: String) throws(Failure) -> URL {
        let url = try Self.normalise(input)
        store.set(url.absoluteString, forKey: Self.key)
        return url
    }

    /// Accepts `http(s)://host[:port][/path]` or a bare `host[:port]` (HTTP
    /// for a home-network host, HTTPS otherwise); drops query and fragment,
    /// lowercases the host, leaves out the default port.
    static func normalise(_ input: String) throws(Failure) -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalid }
        let bare = !text.contains("://")
        guard var parts = URLComponents(string: bare ? "https://" + text : text),
              let host = parts.percentEncodedHost?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { throw .invalid }
        let scheme = bare ? (HomeNetwork.contains(host: host) ? "http" : "https") : parts.scheme?.lowercased()
        switch scheme {
        case "https": break
        case "http": guard HomeNetwork.contains(host: host) else { throw .httpNotLocal }
        default: throw .invalid
        }
        parts.scheme = scheme
        parts.percentEncodedHost = host
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        parts.query = nil
        parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        guard let url = parts.url, Origin.canonical(url) != nil else { throw .invalid }
        return url
    }
}
