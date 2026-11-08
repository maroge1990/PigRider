import Foundation

/// An error reply. `name` is the `DOMException` name the polyfill throws.
struct BridgeError: Error, Equatable, Sendable {
    enum Name: String, CaseIterable, Sendable {
        case notFoundError = "NotFoundError"
        case networkError = "NetworkError"
        case securityError = "SecurityError"
        case notSupportedError = "NotSupportedError"
        case invalidStateError = "InvalidStateError"
        case timeoutError = "TimeoutError"
        case abortError = "AbortError"
        case dataError = "DataError"
    }

    let name: Name
    let message: String

    init(_ name: Name, _ message: String) {
        self.name = name
        self.message = message
    }

    static let noDeviceSelected = BridgeError(.notFoundError, "No device selected.")
    static let serviceNotAllowed = BridgeError(.securityError, "Service not allowed for this device.")
    static let disconnected = BridgeError(.networkError, "Disconnected.")
    static let deviceNotFound = BridgeError(.notFoundError, "Device not found.")
    static let gattDisconnected = BridgeError(.networkError, "GATT Server is disconnected.")
    static let timedOut = BridgeError(.networkError, "GATT operation timed out.")
    static let documentChanged = BridgeError(.abortError, "The page was reloaded.")
}

/// Web Bluetooth's `BluetoothCharacteristicProperties`, listed in its order.
struct CharacteristicProperties: OptionSet, Hashable, Sendable {
    let rawValue: UInt16

    static let broadcast = Self(rawValue: 1 << 0)
    static let read = Self(rawValue: 1 << 1)
    static let writeWithoutResponse = Self(rawValue: 1 << 2)
    static let write = Self(rawValue: 1 << 3)
    static let notify = Self(rawValue: 1 << 4)
    static let indicate = Self(rawValue: 1 << 5)
    static let authenticatedSignedWrites = Self(rawValue: 1 << 6)
    static let reliableWrite = Self(rawValue: 1 << 7)
    static let writableAuxiliaries = Self(rawValue: 1 << 8)

    private static let ordered: [(Self, String)] = [
        (.broadcast, "broadcast"), (.read, "read"), (.writeWithoutResponse, "writeWithoutResponse"),
        (.write, "write"), (.notify, "notify"), (.indicate, "indicate"),
        (.authenticatedSignedWrites, "authenticatedSignedWrites"), (.reliableWrite, "reliableWrite"),
        (.writableAuxiliaries, "writableAuxiliaries"),
    ]

    var names: [String] { Self.ordered.filter { contains($0.0) }.map(\.1) }
}

struct DeviceInfo: Equatable, Sendable {
    let id: UUID
    let name: String?

    var jsonObject: [String: Any] { ["id": id.uuidString, "name": name ?? NSNull()] }
}

enum ReplyValue: Equatable, Sendable {
    case none
    case device(DeviceInfo)
    case devices([DeviceInfo])
    case epoch(Int)
    case properties(CharacteristicProperties)

    var jsonObject: Any {
        switch self {
        case .none: NSNull()
        case .device(let device): device.jsonObject
        case .devices(let devices): devices.map(\.jsonObject)
        case .epoch(let epoch): ["epoch": epoch]
        case .properties(let properties): ["properties": properties.names]
        }
    }
}

/// The reply to one call: `{ok: true, value}` or `{ok: false, error: {name, message}}`.
enum BridgeReply: Equatable, Sendable {
    case success(ReplyValue)
    case failure(BridgeError)

    /// What the `WKScriptMessageHandlerWithReply` hands back to the page.
    var jsonObject: [String: Any] {
        switch self {
        case .success(let value): ["ok": true, "value": value.jsonObject]
        case .failure(let error): ["ok": false, "error": ["name": error.name.rawValue, "message": error.message]]
        }
    }
}

/// An event for `globalThis.__pigriderBle.dispatch(e)`.
enum BridgeEvent: Equatable, Sendable {
    case value(id: UUID, epoch: Int, key: CharacteristicKey, value: Data)
    case disconnected(id: UUID, epoch: Int)
    case advertisement(watchId: String, id: UUID, name: String?, rssi: Int)

    var jsonObject: [String: Any] {
        switch self {
        case let .value(id, epoch, key, value):
            ["type": "value", "id": id.uuidString, "epoch": epoch, "service": key.service.string,
             "characteristic": key.characteristic.string, "value": value.base64EncodedString()]
        case let .disconnected(id, epoch):
            ["type": "disconnected", "id": id.uuidString, "epoch": epoch]
        case let .advertisement(watchId, id, name, rssi):
            ["type": "advertisement", "watchId": watchId, "id": id.uuidString, "name": name ?? NSNull(), "rssi": rssi]
        }
    }
}
