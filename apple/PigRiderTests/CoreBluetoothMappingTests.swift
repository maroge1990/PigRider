import CoreBluetooth
import Foundation
import Testing
@testable import PigRider

/// The pure translations in the CoreBluetooth adapters.
struct CoreBluetoothMappingTests {
    @Test func shortCBUUIDsBecome128Bit() {
        #expect(CBUUID(string: "1826").bluetoothUUID == uuid("1826"))
        #expect(CBUUID(string: "00000001-19CA-4651-86E5-FA29DCDD09D1").bluetoothUUID
            == uuid("00000001-19ca-4651-86e5-fa29dcdd09d1"))
    }

    @Test func characteristicPropertiesMapToWebNames() {
        let properties = CharacteristicProperties([.write, .indicate, .writeWithoutResponse])
        #expect(properties.names == ["writeWithoutResponse", "write", "indicate"])
    }

    @Test func attErrorsMapAsInChrome() {
        func mapped(_ code: CBATTError.Code) -> BridgeError.Name? {
            BridgeError.gatt(NSError(domain: CBATTErrorDomain, code: code.rawValue))?.name
        }
        #expect(mapped(.writeNotPermitted) == .notSupportedError)
        #expect(mapped(.insufficientEncryption) == .securityError)
        #expect(mapped(.unlikelyError) == .networkError)
        #expect(BridgeError.gatt(nil) == nil)
        #expect(BridgeError.gatt(CocoaError(.featureUnsupported))?.name == .networkError)
    }
}
