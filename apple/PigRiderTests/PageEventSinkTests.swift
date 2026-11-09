import Foundation
import Testing
@testable import PigRider

@MainActor
final class FakePage: PageScriptRunning {
    var scripts: [(body: String, arguments: [String: Any])] = []

    func runPageScript(_ body: String, arguments: [String: Any]) {
        scripts.append((body, arguments))
    }
}

@MainActor
struct PageEventSinkTests {
    let page = FakePage()
    let sink = PageEventSink()

    @Test func eachEventIsDispatchedSynchronouslyInOrder() {
        sink.page = page
        let events: [BridgeEvent] = [
            .value(id: kickrID, epoch: 1, key: bikeData, value: Data([1])),
            .disconnected(id: kickrID, epoch: 1),
            .advertisement(watchId: "w1", id: kickrID, name: nil, rssi: -60),
        ]
        for event in events { sink.send(event) }
        #expect(page.scripts.map(\.body) == Array(repeating: "globalThis.__pigriderBle.dispatch(e)", count: 3))
        #expect(page.scripts.map { Set($0.arguments.keys) } == Array(repeating: ["e"], count: 3))
        for (script, event) in zip(page.scripts, events) {
            #expect(ProtocolFixture.jsonEqual(script.arguments["e"]!, event.jsonObject))
        }
    }

    @Test func eventsWithoutAPageAreDropped() {
        sink.send(.disconnected(id: kickrID, epoch: 1))
        sink.page = page
        sink.send(.disconnected(id: kickrID, epoch: 2))
        #expect(page.scripts.count == 1)
    }
}
