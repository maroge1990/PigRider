import Foundation

/// A Bluetooth UUID in the protocol's canonical form: a lowercase 128-bit
/// string (`0000180d-0000-1000-8000-00805f9b34fb`).
struct BluetoothUUID: Hashable, Sendable, Codable, CustomStringConvertible {
    let string: String

    private static let baseSuffix = "-0000-1000-8000-00805f9b34fb"

    /// Accepts only the canonical form, as the protocol requires of the page.
    init?(canonical text: String) {
        guard Self.isCanonical(text) else { return nil }
        string = text
    }

    /// Accepts 16- and 32-bit short forms and 128-bit strings in any case, as
    /// CoreBluetooth's `CBUUID.uuidString` produces them.
    init?(normalizing text: String) {
        let lower = text.lowercased()
        let candidate: String
        switch lower.count {
        case 4: candidate = "0000" + lower + Self.baseSuffix
        case 8: candidate = lower + Self.baseSuffix
        default: candidate = lower
        }
        self.init(canonical: candidate)
    }

    var description: String { string }

    private static func isCanonical(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == UInt8(ascii: "-") else { return false }
            default:
                let isDigit = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                let isLowerHex = (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                guard isDigit || isLowerHex else { return false }
            }
        }
        return true
    }

    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = BluetoothUUID(canonical: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a canonical UUID: \(text)"))
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

/// One characteristic of one service, as the protocol addresses it.
struct CharacteristicKey: Hashable, Sendable {
    let service: BluetoothUUID
    let characteristic: BluetoothUUID
}
