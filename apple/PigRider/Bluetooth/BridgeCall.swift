import Foundation

/// A call from the polyfill, decoded and validated against the limits in
/// `apple/docs/bridge-protocol.md`. Grant checks happen later, in the bridge.
enum BridgeCall: Equatable, Sendable {
    case requestDevice(filters: [RequestFilter], optionalServices: [BluetoothUUID])
    case getDevices
    case forget(id: UUID)
    case watchAdvertisements(id: UUID, watchId: String)
    case unwatchAdvertisements(watchId: String)
    case connect(id: UUID)
    case disconnect(id: UUID, epoch: Int?)
    case getPrimaryService(id: UUID, service: BluetoothUUID)
    case getCharacteristic(id: UUID, key: CharacteristicKey)
    case startNotifications(id: UUID, key: CharacteristicKey)
    case writeValue(id: UUID, key: CharacteristicKey, value: Data, withResponse: Bool)
    case reportUnsupported(method: String)
    /// Not Bluetooth: the page's `navigator.clipboard.writeText`, which WebKit
    /// withholds over plain HTTP (the polyfill provides it there).
    case copyText(text: String)

    static let ops = [
        "requestDevice", "getDevices", "forget", "watchAdvertisements", "unwatchAdvertisements", "connect",
        "disconnect", "getPrimaryService", "getCharacteristic", "startNotifications", "writeValue", "reportUnsupported",
        "copyText",
    ]

    static let maxValueBytes = 512
    static let maxFilters = 8
    static let maxServices = 16
    static let maxStringBytes = 248
    /// A device report with `?debug=controller` (3000 entries) fits.
    static let maxTextBytes = 1 << 20

    /// Convenience for tests and call sites that address a characteristic by its two UUIDs.
    static func getCharacteristic(id: UUID, service: BluetoothUUID, characteristic: BluetoothUUID) -> BridgeCall {
        .getCharacteristic(id: id, key: CharacteristicKey(service: service, characteristic: characteristic))
    }

    static func startNotifications(id: UUID, service: BluetoothUUID, characteristic: BluetoothUUID) -> BridgeCall {
        .startNotifications(id: id, key: CharacteristicKey(service: service, characteristic: characteristic))
    }

    static func writeValue(id: UUID, service: BluetoothUUID, characteristic: BluetoothUUID, value: Data,
                           withResponse: Bool) -> BridgeCall {
        .writeValue(id: id, key: CharacteristicKey(service: service, characteristic: characteristic),
                    value: value, withResponse: withResponse)
    }

    /// Decodes a message body as WebKit delivers it (`NSDictionary` of
    /// `NSString`/`NSNumber`/`NSArray`) or as `JSONSerialization` produces it.
    /// Unknown `op` → `NotSupportedError`; anything missing, mistyped or too
    /// large → `DataError`.
    static func decode(_ body: Any) -> Result<BridgeCall, BridgeError> {
        do throws(BridgeError) {
            return .success(try decodeOrThrow(body))
        } catch {
            return .failure(error)
        }
    }

    private static func decodeOrThrow(_ body: Any) throws(BridgeError) -> BridgeCall {
        guard let dict = body as? [String: Any] else { throw invalid("message") }
        let args = Args(dict: dict)
        guard let op = dict["op"] as? String else { throw invalid("op") }
        switch op {
        case "requestDevice":
            let filters = try args.filters()
            let optional = try args.optionalUUIDList("optionalServices") ?? []
            var all = Set(optional)
            for filter in filters { all.formUnion(filter.services ?? []) }
            guard all.count <= maxServices else { throw invalid("services") }
            return .requestDevice(filters: filters, optionalServices: optional)
        case "getDevices":
            return .getDevices
        case "forget":
            return .forget(id: try args.deviceID())
        case "watchAdvertisements":
            return .watchAdvertisements(id: try args.deviceID(), watchId: try args.string("watchId"))
        case "unwatchAdvertisements":
            return .unwatchAdvertisements(watchId: try args.string("watchId"))
        case "connect":
            return .connect(id: try args.deviceID())
        case "disconnect":
            return .disconnect(id: try args.deviceID(), epoch: try args.optionalInteger("epoch"))
        case "getPrimaryService":
            return .getPrimaryService(id: try args.deviceID(), service: try args.uuid("service"))
        case "getCharacteristic":
            return .getCharacteristic(id: try args.deviceID(), key: try args.characteristicKey())
        case "startNotifications":
            return .startNotifications(id: try args.deviceID(), key: try args.characteristicKey())
        case "writeValue":
            return .writeValue(id: try args.deviceID(), key: try args.characteristicKey(),
                               value: try args.bytes("value"), withResponse: try args.boolean("withResponse"))
        case "reportUnsupported":
            return .reportUnsupported(method: try args.string("method"))
        case "copyText":
            return .copyText(text: try args.text("text"))
        default:
            throw BridgeError(.notSupportedError, "Unknown op.")
        }
    }

    fileprivate static func invalid(_ key: String) -> BridgeError {
        BridgeError(.dataError, "Invalid argument: \(key).")
    }
}

/// Typed access to a message's arguments; every failure is a `DataError`.
private struct Args {
    let dict: [String: Any]

    func string(_ key: String) throws(BridgeError) -> String {
        guard let value = Self.limitedString(dict[key]) else { throw BridgeCall.invalid(key) }
        return value
    }

    /// Free text up to `maxTextBytes` (UTF-8).
    func text(_ key: String) throws(BridgeError) -> String {
        guard let value = dict[key] as? String, value.utf8.count <= BridgeCall.maxTextBytes else {
            throw BridgeCall.invalid(key)
        }
        return value
    }

    func deviceID() throws(BridgeError) -> UUID {
        guard let text = dict["id"] as? String, let id = UUID(uuidString: text) else { throw BridgeCall.invalid("id") }
        return id
    }

    func uuid(_ key: String) throws(BridgeError) -> BluetoothUUID {
        guard let text = dict[key] as? String, let id = BluetoothUUID(canonical: text) else { throw BridgeCall.invalid(key) }
        return id
    }

    func characteristicKey() throws(BridgeError) -> CharacteristicKey {
        CharacteristicKey(service: try uuid("service"), characteristic: try uuid("characteristic"))
    }

    func boolean(_ key: String) throws(BridgeError) -> Bool {
        guard let number = dict[key] as? NSNumber, Self.isBoolean(number) else { throw BridgeCall.invalid(key) }
        return number.boolValue
    }

    func optionalInteger(_ key: String) throws(BridgeError) -> Int? {
        guard let raw = dict[key], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, !Self.isBoolean(number) else { throw BridgeCall.invalid(key) }
        let double = number.doubleValue
        guard double.rounded() == double, double >= 0, double <= Double(Int32.max) else { throw BridgeCall.invalid(key) }
        return Int(double)
    }

    func bytes(_ key: String) throws(BridgeError) -> Data {
        // Base64 of 512 bytes is at most 684 characters; refuse longer input before decoding it.
        let maxEncoded = (BridgeCall.maxValueBytes + 2) / 3 * 4
        guard let text = dict[key] as? String, text.utf8.count <= maxEncoded,
              let data = Data(base64Encoded: text), data.count <= BridgeCall.maxValueBytes else {
            throw BridgeCall.invalid(key)
        }
        return data
    }

    func optionalUUIDList(_ key: String) throws(BridgeError) -> [BluetoothUUID]? {
        guard let raw = dict[key] else { return nil }
        return try Self.uuidList(raw, key: key)
    }

    func filters() throws(BridgeError) -> [RequestFilter] {
        guard let list = dict["filters"] as? [Any], (1...BridgeCall.maxFilters).contains(list.count) else {
            throw BridgeCall.invalid("filters")
        }
        var filters: [RequestFilter] = []
        for item in list {
            guard let raw = item as? [String: Any] else { throw BridgeCall.invalid("filters") }
            filters.append(try Self.filter(raw))
        }
        return filters
    }

    private static func filter(_ raw: [String: Any]) throws(BridgeError) -> RequestFilter {
        var filter = RequestFilter()
        if let services = raw["services"] {
            let list = try uuidList(services, key: "services")
            guard !list.isEmpty else { throw BridgeCall.invalid("services") }
            filter.services = list
        }
        if let name = raw["name"] {
            guard let value = limitedString(name) else { throw BridgeCall.invalid("name") }
            filter.name = value
        }
        if let prefix = raw["namePrefix"] {
            guard let value = limitedString(prefix), !value.isEmpty else { throw BridgeCall.invalid("namePrefix") }
            filter.namePrefix = value
        }
        if let manufacturer = raw["manufacturerData"] {
            guard let list = manufacturer as? [Any], !list.isEmpty else { throw BridgeCall.invalid("manufacturerData") }
            var ids: [UInt16] = []
            for entry in list {
                guard let entry = entry as? [String: Any], let number = entry["companyIdentifier"] as? NSNumber,
                      !isBoolean(number), number.doubleValue.rounded() == number.doubleValue,
                      (0...Double(UInt16.max)).contains(number.doubleValue) else {
                    throw BridgeCall.invalid("companyIdentifier")
                }
                ids.append(UInt16(number.doubleValue))
            }
            filter.manufacturerCompanyIdentifiers = ids
        }
        guard filter != RequestFilter() else { throw BridgeCall.invalid("filters") }
        return filter
    }

    private static func uuidList(_ raw: Any, key: String) throws(BridgeError) -> [BluetoothUUID] {
        guard let list = raw as? [Any], list.count <= BridgeCall.maxServices else { throw BridgeCall.invalid(key) }
        var result: [BluetoothUUID] = []
        for item in list {
            guard let text = item as? String, let id = BluetoothUUID(canonical: text) else { throw BridgeCall.invalid(key) }
            result.append(id)
        }
        return result
    }

    private static func limitedString(_ raw: Any?) -> String? {
        guard let text = raw as? String, text.utf8.count <= BridgeCall.maxStringBytes else { return nil }
        return text
    }

    /// `NSNumber` bridges to `Bool` for any 0/1, so check for a real `CFBoolean`.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
