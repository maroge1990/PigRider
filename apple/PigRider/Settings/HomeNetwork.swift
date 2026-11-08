import Darwin

/// Server hosts in the form WebKit serialises them, so the saved origin equals
/// the page's `location.origin` (URL Standard host parsing and serialising).
enum ServerHost {
    /// The browser's form of `host` (lowercase, as URLComponents gives it), or
    /// nil for a host WebKit would rewrite in ways not mirrored here: IPv4
    /// shorthand (`0x08.8.8.8`, `010.0.0.1`, `10.1`), IPv6 with a zone or an
    /// embedded IPv4, and anything outside `[a-z0-9._-]` (IDN, percent-encoding).
    static func canonical(_ rawHost: String) -> String? {
        let host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return ipv6Pieces(String(host.dropFirst().dropLast())).map { "[\(serialise($0))]" }
        }
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(isHostCharacter) else { return nil }
        var labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // The URL Standard's "ends in a number" check: such a host is IPv4 or invalid.
        if labels.count > 1 && labels.last == "" { labels.removeLast() }
        guard let last = labels.last, isIPv4Number(last) else { return host }
        guard labels.count == 4, labels.allSatisfy(isDecimalOctet) else { return nil }
        return labels.joined(separator: ".")
    }

    static func isIPv4Number(_ label: String) -> Bool {
        if label.hasPrefix("0x") { return label.dropFirst(2).allSatisfy(\.isHexDigit) }
        return !label.isEmpty && label.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// `0`–`255` without leading zeros (which the URL Standard reads as octal).
    static func isDecimalOctet(_ label: String) -> Bool {
        guard let value = Int(label), value <= 255 else { return false }
        return label == String(value)
    }

    /// The eight 16-bit pieces; nil for zones, embedded IPv4 or bad syntax.
    static func ipv6Pieces(_ text: String) -> [UInt16]? {
        guard !text.contains("%"), !text.contains(".") else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        return stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
    }

    /// URL Standard IPv6 serialiser: lowercase hex, the first longest run of two
    /// or more zero pieces compressed to `::`.
    static func serialise(_ pieces: [UInt16]) -> String {
        var compress: Int?
        var longest = 1
        var index = 0
        while index < pieces.count {
            var end = index
            while end < pieces.count && pieces[end] == 0 { end += 1 }
            if end - index > longest { compress = index; longest = end - index }
            index = max(end, index + 1)
        }
        var output = ""
        var skipping = false
        for (index, piece) in pieces.enumerated() {
            if skipping && piece == 0 { continue }
            skipping = false
            if compress == index {
                output += index == 0 ? "::" : ":"
                skipping = true
                continue
            }
            output += String(piece, radix: 16)
            if index != 7 { output += ":" }
        }
        return output
    }

    private static func isHostCharacter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "." || scalar == "_"
    }
}

/// Whether a (canonical) host is on the home network, where the server may use plain
/// HTTP. The rule matches what ATS's `NSAllowsLocalNetworking` exempts
/// (IP addresses, `.local` names, names without a dot), narrowed to private
/// addresses, and it refuses anything WebKit's URL parser could read as a
/// different IPv4 address (`010.0.0.1`, `0x0a.0.0.1`, `10.1`, `167772161`).
enum HomeNetwork {
    /// `host` must be in `ServerHost.canonical` form.
    static func contains(host: String) -> Bool {
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return ServerHost.ipv6Pieces(String(host.dropFirst().dropLast())).map(isPrivateIPv6) ?? false
        }
        var name = host
        if name.hasSuffix(".") { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !labels.isEmpty, labels.allSatisfy(isHostnameLabel) else { return false }
        if labels.allSatisfy(ServerHost.isDecimalOctet) {
            return labels.count == 4 && isPrivateIPv4(labels.compactMap { UInt8($0) })
        }
        // Any label the URL Standard reads as an IPv4 number makes the host an address (or invalid).
        if labels.contains(where: ServerHost.isIPv4Number) { return false }
        if labels.count == 1 { return true }  // e.g. `passyflix`, `localhost`
        return labels.last == "local"
    }

    /// `[a-z0-9-]`, 1–63 characters, no leading or trailing hyphen.
    private static func isHostnameLabel(_ label: String) -> Bool {
        guard (1...63).contains(label.count), !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    private static func isPrivateIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// `::1`, unique local `fc00::/7` and link-local `fe80::/10`.
    private static func isPrivateIPv6(_ pieces: [UInt16]) -> Bool {
        if pieces == [0, 0, 0, 0, 0, 0, 0, 1] { return true }
        return pieces[0] & 0xfe00 == 0xfc00 || pieces[0] & 0xffc0 == 0xfe80
    }
}
