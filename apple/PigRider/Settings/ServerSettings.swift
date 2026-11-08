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

/// The self-hosted server the web view loads. HTTPS only (ATS stays on).
@MainActor
final class ServerSettings {
    enum Failure: Error, Equatable {
        case invalid
        case notHTTPS
    }

    /// The scheme rule, in one place: the only scheme a server URL may use,
    /// also assumed for a bare `host[:port]`. Everything downstream (origin,
    /// navigation policy, bridge origin check) works on canonical origins and
    /// accepts http as well. Allowing plain HTTP would change this rule (and
    /// `defaultPort`) and add an ATS exception in `project.yml`.
    static let scheme = "https"
    static let defaultPort = 443

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

    /// Accepts `https://host[:port][/path]` or a bare `host[:port]`; drops query
    /// and fragment, lowercases the host, leaves out the default port.
    static func normalise(_ input: String) throws(Failure) -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalid }
        if !text.contains("://") { text = "\(scheme)://" + text }
        guard var parts = URLComponents(string: text), let given = parts.scheme?.lowercased() else { throw .invalid }
        guard given == scheme else { throw given == "http" ? .notHTTPS : .invalid }
        guard let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { throw .invalid }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if parts.port == defaultPort { parts.port = nil }
        parts.query = nil
        parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        guard let url = parts.url else { throw .invalid }
        return url
    }
}
