import Foundation
import Testing
@testable import PigRider

struct BridgeCallTests {
    @Test func everyValidFixtureCallDecodes() throws {
        let calls = try ProtocolFixture.entries("calls").filter { $0["valid"] as? Bool == true }
        #expect(!calls.isEmpty)
        for entry in calls {
            let name = entry["name"] as? String ?? "?"
            let result = BridgeCall.decode(entry["message"] as Any)
            if case .failure(let error) = result {
                Issue.record("\(name): \(error)")
            }
        }
    }

    @Test func everyInvalidFixtureCallFailsWithTheFixturesErrorName() throws {
        let calls = try ProtocolFixture.entries("calls").filter { $0["valid"] as? Bool == false }
        #expect(!calls.isEmpty)
        for entry in calls {
            let name = entry["name"] as? String ?? "?"
            let expected = entry["error"] as? String
            switch BridgeCall.decode(entry["message"] as Any) {
            case .success(let call): Issue.record("\(name): decoded as \(call)")
            case .failure(let error): #expect(error.name.rawValue == expected, "\(name)")
            }
        }
    }

    @Test func everyFixtureOpIsKnownAndEveryErrorNameExists() throws {
        let root = try ProtocolFixture.load()
        let ops = try #require(root["ops"] as? [String])
        #expect(Set(ops) == Set(BridgeCall.ops))
        let names = try #require(root["errorNames"] as? [String])
        #expect(Set(names) == Set(BridgeError.Name.allCases.map(\.rawValue)))
    }

    @Test func aTrainerRequestDecodesItsFilters() throws {
        let message = try ProtocolFixture.entry("calls", named: "request a trainer by service")["message"] as Any
        let call = try BridgeCall.decode(message).get()
        #expect(call == .requestDevice(
            filters: [RequestFilter(services: [uuid("1826")]), RequestFilter(services: [uuid("1818")])],
            optionalServices: [uuid("1826"), uuid("1818")]))
    }

    @Test func aZwiftRequestDecodesManufacturerAndPrefix() throws {
        let message = try ProtocolFixture.entry("calls", named: "request a Zwift controller by manufacturer or name prefix")["message"] as Any
        let call = try BridgeCall.decode(message).get()
        #expect(call == .requestDevice(
            filters: [RequestFilter(manufacturerCompanyIdentifiers: [2378]), RequestFilter(namePrefix: "Zwift")],
            optionalServices: [uuid("00000001-19ca-4651-86e5-fa29dcdd09d1")]))
    }

    @Test func aWriteDecodesBytesAndWriteType() throws {
        let message = try ProtocolFixture.entry("calls", named: "write RideOn without response")["message"] as Any
        let call = try BridgeCall.decode(message).get()
        #expect(call == .writeValue(
            id: kickrID, service: uuid("00000001-19ca-4651-86e5-fa29dcdd09d1"),
            characteristic: uuid("00000003-19ca-4651-86e5-fa29dcdd09d1"),
            value: Data("RideOn".utf8), withResponse: false))
    }

    @Test func disconnectCarriesAnOptionalEpoch() throws {
        let stale = try ProtocolFixture.entry("calls", named: "disconnect a stale attempt")["message"] as Any
        #expect(try BridgeCall.decode(stale).get() == .disconnect(id: kickrID, epoch: 3))
        let page = try ProtocolFixture.entry("calls", named: "disconnect (page)")["message"] as Any
        #expect(try BridgeCall.decode(page).get() == .disconnect(id: kickrID, epoch: nil))
    }

    @Test func aNumberIsNotABoolean() {
        let message: [String: Any] = [
            "op": "writeValue", "id": kickrID.uuidString, "service": uuid("1826").string,
            "characteristic": uuid("2ad9").string, "value": "AA==", "withResponse": 1,
        ]
        #expect(throws: BridgeError.self) { try BridgeCall.decode(message).get() }
    }

    @Test func aBooleanIsNotAnEpoch() {
        let message: [String: Any] = ["op": "disconnect", "id": kickrID.uuidString, "epoch": true]
        #expect(throws: BridgeError.self) { try BridgeCall.decode(message).get() }
    }

    @Test func aFractionalEpochIsRejected() {
        let message: [String: Any] = ["op": "disconnect", "id": kickrID.uuidString, "epoch": 2.5]
        #expect(throws: BridgeError.self) { try BridgeCall.decode(message).get() }
    }

    @Test func anEmptyFilterIsRejected() {
        let message: [String: Any] = ["op": "requestDevice", "filters": [[String: Any]()], "optionalServices": [String]()]
        #expect(throws: BridgeError.self) { try BridgeCall.decode(message).get() }
    }

    @Test func aCompanyIdentifierMustFitSixteenBits() {
        let message: [String: Any] = ["op": "requestDevice", "filters": [["manufacturerData": [["companyIdentifier": 70000]]]]]
        #expect(throws: BridgeError.self) { try BridgeCall.decode(message).get() }
    }

    @Test func sixteenServicesAcrossFiltersAndOptionalServicesAreTheLimit() {
        let services = (0..<16).map { String(format: "%08x-0000-1000-8000-00805f9b34fb", $0) }
        let ok: [String: Any] = ["op": "requestDevice", "filters": [["services": [services[0]]]], "optionalServices": services]
        #expect(throws: Never.self) { try BridgeCall.decode(ok).get() }
        let tooMany: [String: Any] = ["op": "requestDevice", "filters": [["services": ["00000099-0000-1000-8000-00805f9b34fb"]]], "optionalServices": services]
        #expect(throws: BridgeError.self) { try BridgeCall.decode(tooMany).get() }
    }

    @Test func aValueOfExactly512BytesIsAllowed() {
        let message: [String: Any] = [
            "op": "writeValue", "id": kickrID.uuidString, "service": uuid("1826").string,
            "characteristic": uuid("2ad9").string, "value": Data(count: 512).base64EncodedString(), "withResponse": true,
        ]
        #expect(throws: Never.self) { try BridgeCall.decode(message).get() }
    }

    @Test func anIdMustBeAUUID() {
        let message: [String: Any] = ["op": "connect", "id": "not-a-uuid"]
        let result = BridgeCall.decode(message)
        #expect(throws: BridgeError(.dataError, "Invalid argument: id.")) { try result.get() }
    }

    @Test func aBodyThatIsNotAnObjectIsADataError() {
        #expect(throws: BridgeError.self) { try BridgeCall.decode("connect").get() }
    }
}
