import Foundation
import Testing
@testable import PigRider

/// Replies and events serialise exactly as the shared fixtures show.
struct BridgeMessagesTests {
    func expectReply(_ reply: BridgeReply, matches name: String) throws {
        let fixture = try #require(try ProtocolFixture.entry("replies", named: name)["reply"])
        #expect(ProtocolFixture.jsonEqual(reply.jsonObject, fixture), "\(name): \(reply.jsonObject)")
    }

    func expectEvent(_ event: BridgeEvent, matches name: String) throws {
        let fixture = try #require(try ProtocolFixture.entry("events", named: name)["event"])
        #expect(ProtocolFixture.jsonEqual(event.jsonObject, fixture), "\(name): \(event.jsonObject)")
    }

    @Test func replies() throws {
        try expectReply(.success(.device(DeviceInfo(id: kickrID, name: "KICKR CORE 1234"))), matches: "device chosen")
        try expectReply(.success(.devices([DeviceInfo(id: kickrID, name: "KICKR CORE 1234")])), matches: "granted devices")
        try expectReply(.success(.epoch(4)), matches: "connected")
        try expectReply(.success(.properties([.write, .indicate])), matches: "characteristic properties")
        try expectReply(.success(.none), matches: "done")
        try expectReply(.failure(.noDeviceSelected), matches: "chooser cancelled")
        try expectReply(.failure(.serviceNotAllowed), matches: "service outside the grant")
        try expectReply(.failure(.disconnected), matches: "link lost")
        try expectReply(.failure(BridgeError(.notSupportedError, "Characteristic does not support write.")), matches: "write type not supported")
    }

    @Test func events() throws {
        try expectEvent(.value(id: kickrID, epoch: 4, key: CharacteristicKey(service: uuid("1826"), characteristic: uuid("2ad2")),
                               value: Data(base64Encoded: "RAAAAAAAAA==")!), matches: "indoor bike data")
        try expectEvent(.disconnected(id: kickrID, epoch: 4), matches: "link dropped")
        try expectEvent(.advertisement(watchId: "w1", id: kickrID, name: "Zwift Click", rssi: -61), matches: "advertisement seen")
    }

    @Test func anUnknownNameIsNull() {
        let reply = BridgeReply.success(.device(DeviceInfo(id: kickrID, name: nil))).jsonObject
        let value = reply["value"] as? [String: Any]
        #expect(value?["name"] is NSNull)
    }

    @Test func propertiesAreListedInWebBluetoothOrder() {
        let all: CharacteristicProperties = [.indicate, .notify, .write, .writeWithoutResponse, .read, .broadcast,
                                             .authenticatedSignedWrites, .reliableWrite, .writableAuxiliaries]
        #expect(all.names == ["broadcast", "read", "writeWithoutResponse", "write", "notify", "indicate",
                              "authenticatedSignedWrites", "reliableWrite", "writableAuxiliaries"])
    }
}
