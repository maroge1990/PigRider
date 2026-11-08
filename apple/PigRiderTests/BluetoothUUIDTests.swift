import Foundation
import Testing
@testable import PigRider

struct BluetoothUUIDTests {
    @Test func canonicalAcceptsLowercase128Bit() {
        let id = BluetoothUUID(canonical: "00001826-0000-1000-8000-00805f9b34fb")
        #expect(id?.string == "00001826-0000-1000-8000-00805f9b34fb")
    }

    @Test(arguments: ["1826", "00001826-0000-1000-8000-00805F9B34FB", "00001826000010008000-00805f9b34fb", "", "0000182g-0000-1000-8000-00805f9b34fb"])
    func canonicalRejectsAnythingElse(_ text: String) {
        #expect(BluetoothUUID(canonical: text) == nil)
    }

    @Test func normalisingExpands16BitShortForms() {
        #expect(BluetoothUUID(normalizing: "180D")?.string == "0000180d-0000-1000-8000-00805f9b34fb")
    }

    @Test func normalisingExpands32BitShortForms() {
        #expect(BluetoothUUID(normalizing: "0000FFF1")?.string == "0000fff1-0000-1000-8000-00805f9b34fb")
    }

    @Test func normalisingLowercasesFullForms() {
        #expect(BluetoothUUID(normalizing: "00000001-19CA-4651-86E5-FA29DCDD09D1")?.string == "00000001-19ca-4651-86e5-fa29dcdd09d1")
    }

    @Test(arguments: ["18", "xyz1", "00001826-0000-1000-8000"])
    func normalisingRejectsGarbage(_ text: String) {
        #expect(BluetoothUUID(normalizing: text) == nil)
    }
}
