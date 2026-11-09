import CoreBluetooth
import Foundation

// Thin adapters from CoreBluetooth to the bridge's protocols. They only
// translate types and forward callbacks; all logic is in BluetoothBridge,
// which the tests cover with fakes (the simulator has no Bluetooth).
//
// The central runs on the main queue (`queue: nil`), so every delegate
// callback arrives on the main thread. The conformances are
// `@preconcurrency`: the main-actor methods satisfy CoreBluetooth's
// nonisolated requirements, and Swift checks the main thread at run time.

extension BluetoothBridge {
    /// A bridge on CoreBluetooth, for the app.
    static func live(grants: GrantStore, events: any EventSink, chooser: any ChooserPresenting,
                     onUnsupported: @escaping @MainActor (String) -> Void,
                     copyPrompt: any CopyPrompting) -> BluetoothBridge {
        BluetoothBridge(central: CoreBluetoothCentral(), grants: grants, events: events, chooser: chooser,
                        scheduler: TaskScheduler(), onUnsupported: onUnsupported, copyPrompt: copyPrompt)
    }
}

@MainActor
final class CoreBluetoothCentral: NSObject, CentralManaging {
    weak var delegate: (any CentralEvents)?
    private var peripherals: [UUID: CoreBluetoothPeripheral] = [:]
    private var createdManager: CBCentralManager?

    /// Created on first use, so the Bluetooth permission prompt appears when
    /// the page first needs Bluetooth, not at launch.
    private var manager: CBCentralManager {
        if let createdManager { return createdManager }
        let manager = CBCentralManager(delegate: self, queue: nil)
        createdManager = manager
        return manager
    }

    var state: CentralState {
        switch manager.state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .resetting: .resetting
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    func startScan() {
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        manager.stopScan()
    }

    func connect(_ peripheral: any PeripheralHandle) {
        guard let peripheral = peripheral as? CoreBluetoothPeripheral else { return }
        manager.connect(peripheral.peripheral)
    }

    func cancelConnection(_ peripheral: any PeripheralHandle) {
        guard let peripheral = peripheral as? CoreBluetoothPeripheral else { return }
        manager.cancelPeripheralConnection(peripheral.peripheral)
    }

    func retrievePeripheral(withIdentifier id: UUID) -> (any PeripheralHandle)? {
        manager.retrievePeripherals(withIdentifiers: [id]).first.map(wrap)
    }

    private func wrap(_ peripheral: CBPeripheral) -> CoreBluetoothPeripheral {
        if let wrapped = peripherals[peripheral.identifier], wrapped.peripheral === peripheral { return wrapped }
        let wrapped = CoreBluetoothPeripheral(peripheral, central: self)
        peripherals[peripheral.identifier] = wrapped
        return wrapped
    }
}

extension CoreBluetoothCentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        delegate?.centralDidUpdateState()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let wrapped = wrap(peripheral)
        var services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        services += advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        var companies: Set<UInt16> = []
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 {
            let bytes = [UInt8](data.prefix(2))
            companies.insert(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
        }
        let ad = Advertisement(
            id: peripheral.identifier,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
            services: Set(services.compactMap(\.bluetoothUUID)),
            manufacturerCompanyIdentifiers: companies,
            rssi: RSSI.intValue)
        delegate?.central(didDiscover: wrapped, advertisement: ad)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        delegate?.central(didConnect: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        delegate?.central(didFailToConnect: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: (any Error)?) {
        delegate?.central(didDisconnect: peripheral.identifier)
    }
}

@MainActor
final class CoreBluetoothPeripheral: NSObject, PeripheralHandle {
    let peripheral: CBPeripheral
    private weak var central: CoreBluetoothCentral?

    init(_ peripheral: CBPeripheral, central: CoreBluetoothCentral) {
        self.peripheral = peripheral
        self.central = central
        super.init()
        peripheral.delegate = self
    }

    private var events: (any CentralEvents)? { central?.delegate }

    var identifier: UUID { peripheral.identifier }
    var name: String? { peripheral.name }
    var state: PeripheralState { PeripheralState(peripheral.state) }
    var canSendWriteWithoutResponse: Bool { peripheral.canSendWriteWithoutResponse }

    func discoverServices() {
        peripheral.discoverServices(nil)
    }

    func discoverCharacteristics(for service: BluetoothUUID) {
        guard let cbService = self.service(service) else {
            report { $0.peripheral(self.identifier, didDiscoverCharacteristics: [], for: service, error: .serviceNotFound) }
            return
        }
        peripheral.discoverCharacteristics(nil, for: cbService)
    }

    func setNotifyValue(_ enabled: Bool, for key: CharacteristicKey) {
        guard let characteristic = characteristic(key) else {
            report { $0.peripheral(self.identifier, didUpdateNotificationStateFor: key, error: .characteristicNotFound) }
            return
        }
        peripheral.setNotifyValue(enabled, for: characteristic)
    }

    func writeValue(_ value: Data, for key: CharacteristicKey, withResponse: Bool) {
        guard let characteristic = characteristic(key) else {
            if withResponse {
                report { $0.peripheral(self.identifier, didWriteValueFor: key, error: .characteristicNotFound) }
            }
            return
        }
        peripheral.writeValue(value, for: characteristic, type: withResponse ? .withResponse : .withoutResponse)
    }

    private func service(_ uuid: BluetoothUUID) -> CBService? {
        peripheral.services?.first { $0.uuid.bluetoothUUID == uuid }
    }

    private func characteristic(_ key: CharacteristicKey) -> CBCharacteristic? {
        service(key.service)?.characteristics?.first { $0.uuid.bluetoothUUID == key.characteristic }
    }

    /// Reports a failure on the next main-queue turn, as CoreBluetooth would,
    /// so the bridge is never re-entered from its own call.
    private func report(_ deliver: @escaping @MainActor (any CentralEvents) -> Void) {
        Task { @MainActor [weak self] in
            guard let events = self?.events else { return }
            deliver(events)
        }
    }

    private static func key(_ characteristic: CBCharacteristic) -> CharacteristicKey? {
        guard let service = characteristic.service?.uuid.bluetoothUUID,
              let uuid = characteristic.uuid.bluetoothUUID else { return nil }
        return CharacteristicKey(service: service, characteristic: uuid)
    }
}

extension CoreBluetoothPeripheral: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let services = (peripheral.services ?? []).compactMap(\.uuid.bluetoothUUID)
        events?.peripheral(identifier, didDiscoverServices: services, error: BridgeError.gatt(error))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: (any Error)?) {
        guard let serviceUUID = service.uuid.bluetoothUUID else { return }
        let characteristics = (service.characteristics ?? []).compactMap { characteristic in
            characteristic.uuid.bluetoothUUID.map {
                DiscoveredCharacteristic(uuid: $0, properties: CharacteristicProperties(characteristic.properties))
            }
        }
        events?.peripheral(identifier, didDiscoverCharacteristics: characteristics, for: serviceUUID,
                           error: BridgeError.gatt(error))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        guard let key = Self.key(characteristic) else { return }
        events?.peripheral(identifier, didUpdateNotificationStateFor: key, error: BridgeError.gatt(error))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        guard let key = Self.key(characteristic) else { return }
        events?.peripheral(identifier, didWriteValueFor: key, error: BridgeError.gatt(error))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        guard let key = Self.key(characteristic) else { return }
        events?.peripheral(identifier, didUpdateValueFor: key, value: characteristic.value, error: BridgeError.gatt(error))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        events?.peripheralIsReadyToSendWriteWithoutResponse(identifier)
    }
}

extension CBUUID {
    /// `uuidString` is "180D" for SIG short forms; the bridge wants 128-bit lowercase.
    var bluetoothUUID: BluetoothUUID? { BluetoothUUID(normalizing: uuidString) }
}

extension CharacteristicProperties {
    init(_ properties: CBCharacteristicProperties) {
        self = []
        let pairs: [(CBCharacteristicProperties, CharacteristicProperties)] = [
            (.broadcast, .broadcast), (.read, .read), (.writeWithoutResponse, .writeWithoutResponse),
            (.write, .write), (.notify, .notify), (.indicate, .indicate),
            (.authenticatedSignedWrites, .authenticatedSignedWrites),
        ]
        // reliableWrite/writableAuxiliaries live in the extended-properties
        // descriptor, which CoreBluetooth does not expose; upstream uses neither.
        for (cb, web) in pairs where properties.contains(cb) { insert(web) }
    }
}

extension BridgeError {
    /// Maps a CoreBluetooth error as Chrome maps GATT errors: "not permitted"
    /// → NotSupportedError, missing authentication/encryption → SecurityError,
    /// anything else → NetworkError.
    static func gatt(_ error: (any Error)?) -> BridgeError? {
        guard let error else { return nil }
        let nsError = error as NSError
        if nsError.domain == CBATTErrorDomain, let code = CBATTError.Code(rawValue: nsError.code) {
            switch code {
            case .readNotPermitted, .writeNotPermitted, .requestNotSupported:
                return BridgeError(.notSupportedError, "GATT operation not permitted.")
            case .insufficientAuthentication, .insufficientEncryption, .insufficientAuthorization:
                return BridgeError(.securityError, "GATT operation not authorized.")
            default:
                break
            }
        }
        return BridgeError(.networkError, "GATT operation failed: \(nsError.localizedDescription)")
    }
}

extension PeripheralState {
    init(_ state: CBPeripheralState) {
        switch state {
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .disconnecting: self = .disconnecting
        // Unknown: assume CoreBluetooth still holds the link, so a drain keeps its fence.
        @unknown default: self = .connected
        }
    }
}
