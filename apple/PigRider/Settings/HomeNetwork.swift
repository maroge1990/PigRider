import Darwin

/// Whether a host is on the home network, where the server may use plain
/// HTTP. The rule matches what ATS's `NSAllowsLocalNetworking` exempts
/// (IP addresses, `.local` names, names without a dot), narrowed to private
/// addresses, and it refuses anything WebKit's URL parser could read as a
/// different IPv4 address (`010.0.0.1`, `0x0a.0.0.1`, `10.1`, `167772161`).
enum HomeNetwork {
    static func contains(host rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            return isPrivateIPv6(String(host.dropFirst().dropLast()))
        }
        if host.contains(":") { return isPrivateIPv6(host) }
        if host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !labels.isEmpty, labels.allSatisfy(isHostnameLabel) else { return false }
        if labels.allSatisfy(isDecimalOctet) { return labels.count == 4 && isPrivateIPv4(labels.compactMap { UInt8($0) }) }
        // Any label WebKit reads as an IPv4 number makes the host an address (or invalid).
        if labels.contains(where: isIPv4Number) { return false }
        if labels.count == 1 { return true }  // e.g. `passyflix`, `localhost`
        return labels.last == "local" && labels.count >= 2
    }

    /// `[a-z0-9-]`, 1–63 characters, no leading or trailing hyphen.
    private static func isHostnameLabel(_ label: String) -> Bool {
        guard (1...63).contains(label.count), !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// `0`–`255` without leading zeros (which WebKit reads as octal).
    private static func isDecimalOctet(_ label: String) -> Bool {
        guard let value = Int(label), value <= 255 else { return false }
        return label == String(value)
    }

    /// What the WHATWG URL parser treats as an IPv4 number: decimal, `0`-prefixed octal or `0x` hex.
    private static func isIPv4Number(_ label: String) -> Bool {
        if label.hasPrefix("0x") { return label.dropFirst(2).allSatisfy(\.isHexDigit) }
        return label.allSatisfy(\.isASCII) && label.allSatisfy(\.isNumber)
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
    private static func isPrivateIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        if bytes == Array(repeating: 0, count: 15) + [1] { return true }
        return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
    }
}
