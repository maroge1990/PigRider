import Foundation
import Testing
@testable import PigRider

/// Background/foreground, document lifetime and server changes.
@MainActor
struct BridgeLifecycleTests {
    let h = BridgeHarness()
    let clickRequest = BridgeCall.requestDevice(
        filters: [RequestFilter(manufacturerCompanyIdentifiers: [0x094A]), RequestFilter(namePrefix: "Zwift")],
        optionalServices: [])

    // MARK: Background

    @Test func backgroundCancelsConnectionsAndRejectsPendingWork() {
        h.connect()
        h.resolve(controlPoint)
        let write = h.write(controlPoint, [1])
        h.bridge.enterBackground()
        #expect(h.central.cancels == [kickrID])
        #expect(write.errorName == .networkError)
        #expect(h.sink.events.isEmpty)
    }

    @Test func foregroundReportsEachDeviceThatWasConnectedOnce() {
        let kickrEpoch = h.connect(kickrID)
        let polarEpoch = h.connect(polarID)
        h.bridge.enterBackground()
        h.bridge.enterForeground()
        #expect(Set(h.sink.events.map(\.jsonDescription)) == [
            BridgeEvent.disconnected(id: kickrID, epoch: kickrEpoch!).jsonDescription,
            BridgeEvent.disconnected(id: polarID, epoch: polarEpoch!).jsonDescription,
        ])
        h.bridge.enterForeground()
        #expect(h.sink.events.count == 2)
    }

    @Test func aConnectionThatSurvivedSuspensionEndsInOneCleanReconnect() {
        h.connect()
        h.bridge.enterBackground()
        // iOS delivers what it queued while the app was suspended.
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([1]), error: nil)
        h.bridge.enterForeground()
        h.bridge.central(didDisconnect: kickrID) // answer to the background cancel
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 1)])
        let epoch = h.connect()
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([2]), error: nil)
        #expect(epoch! > 2)
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 1),
                                  .value(id: kickrID, epoch: epoch!, key: bikeData, value: Data([2]))])
    }

    @Test func aConnectionThatDroppedWhileSuspendedAlsoEndsInOneCleanReconnect() {
        h.connect()
        h.bridge.enterBackground()
        h.bridge.central(didDisconnect: kickrID) // dropped (or our cancel) while suspended
        h.bridge.enterForeground()
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 1)])
        #expect(h.connect() != nil)
        #expect(h.sink.events.count == 1)
    }

    @Test func backgroundBumpsEveryEpoch() {
        h.connect()
        h.bridge.enterBackground()
        h.bridge.enterForeground()
        h.bridge.central(didDisconnect: kickrID)
        #expect(h.connect() == 3)
    }

    @Test func aPendingConnectIsRejectedWithoutALaterEvent() {
        h.grant()
        let attempt = h.call(.connect(id: kickrID))
        h.bridge.enterBackground()
        h.bridge.enterForeground()
        #expect(attempt.errorName == .networkError)
        #expect(h.sink.events.isEmpty)
    }

    @Test func connectInTheBackgroundIsRefused() {
        h.grant()
        h.bridge.enterBackground()
        #expect(h.call(.connect(id: kickrID)).errorName == .networkError)
        #expect(h.central.connects.isEmpty)
    }

    @Test func backgroundPausesTheScanAndKeepsWatchersAndTheChooser() {
        h.grant(kickrID)
        h.call(.watchAdvertisements(id: kickrID, watchId: "w1"))
        let request = h.call(clickRequest)
        h.bridge.enterBackground()
        #expect(!h.central.isScanning)
        #expect(h.presenter.dismissals == 0)
        #expect(request.isPending)
        h.bridge.enterForeground()
        #expect(h.central.isScanning)
        h.sighting(kickrID, name: "KICKR CORE 1234")
        #expect(h.sink.events == [.advertisement(watchId: "w1", id: kickrID, name: "KICKR CORE 1234", rssi: -60)])
    }

    @Test func aWatchAbortedWhileSuspendedIsGoneAndTheOthersStillHear() {
        h.grant(kickrID)
        h.grant(polarID, services: [heartRate])
        h.call(.watchAdvertisements(id: kickrID, watchId: "trainer"))
        h.call(.watchAdvertisements(id: polarID, watchId: "strap"))
        h.bridge.enterBackground()
        h.call(.unwatchAdvertisements(watchId: "trainer"))
        h.bridge.enterForeground()
        h.sighting(kickrID, name: "KICKR CORE 1234")
        h.sighting(polarID, name: "Polar H10")
        #expect(h.sink.events == [.advertisement(watchId: "strap", id: polarID, name: "Polar H10", rssi: -60)])
    }

    // MARK: Document lifetime

    /// A connection with a pending write, a watch and an open chooser, then `change`.
    func busyDocument(then change: () -> Void) -> (write: Replies, request: Replies) {
        h.connect()
        h.resolve(controlPoint)
        let write = h.write(controlPoint, [1])
        h.call(.watchAdvertisements(id: kickrID, watchId: "w1"))
        let request = h.call(clickRequest)
        change()
        return (write, request)
    }

    @Test(arguments: ["reload", "server"])
    func aNewDocumentCancelsEverythingAndRejectsPendingCalls(_ kind: String) {
        let (write, request) = busyDocument {
            if kind == "server" { h.bridge.serverDidChange() } else { h.bridge.documentDidChange() }
        }
        #expect(h.central.cancels == [kickrID])
        #expect(write.all == [.failure(.documentChanged)])
        #expect(request.all == [.failure(.documentChanged)])
        #expect(h.presenter.dismissals == 1)
        #expect(!h.central.isScanning)
        #expect(h.sink.events.isEmpty)
    }

    @Test func lateRepliesAndEventsOfTheOldDocumentAreDropped() {
        let (write, request) = busyDocument { h.bridge.documentDidChange() }
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil)
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([1]), error: nil)
        h.bridge.central(didDisconnect: kickrID)
        h.sighting(kickrID, name: "KICKR CORE 1234")
        h.presenter.pick(kickrID)
        h.scheduler.advance(by: .seconds(30))
        #expect(write.all.count == 1)
        #expect(request.all.count == 1)
        #expect(h.sink.events.isEmpty)
    }

    @Test func grantsSurviveANewDocument() {
        h.grant()
        h.bridge.documentDidChange()
        #expect(h.call(.getDevices).value == .devices([DeviceInfo(id: kickrID, name: "KICKR CORE 1234")]))
    }

    @Test func theNewDocumentCanConnectAgain() {
        h.connect()
        h.bridge.documentDidChange()
        h.bridge.central(didDisconnect: kickrID)
        let epoch = h.connect()
        #expect(epoch == 2)
        #expect(h.call(.getDevices).succeeded)
    }

    @Test func aNewDocumentsConnectWaitsUntilTheOldLinkIsGone() {
        h.grant()
        h.call(.connect(id: kickrID))
        h.bridge.documentDidChange()
        let fresh = h.call(.connect(id: kickrID))
        // The old document's attempt connected late; it is not the new document's link.
        h.bridge.central(didConnect: kickrID)
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([1]), error: nil)
        #expect(fresh.isPending)
        h.bridge.central(didDisconnect: kickrID)
        h.bridge.central(didConnect: kickrID)
        #expect(fresh.epoch == 2)
        #expect(h.central.connects == [kickrID, kickrID])
        #expect(h.sink.events.isEmpty)
    }

    @Test func aConnectQueuedByTheOldDocumentIsDroppedWithIt() {
        h.connect()
        h.call(.disconnect(id: kickrID, epoch: nil))
        let queued = h.call(.connect(id: kickrID))
        h.bridge.documentDidChange()
        h.bridge.central(didDisconnect: kickrID)
        #expect(queued.all == [.failure(.documentChanged)])
        #expect(h.central.connects == [kickrID])
    }

    @Test func aNewDocumentForgetsDevicesDroppedInTheBackground() {
        h.connect()
        h.bridge.enterBackground()
        h.bridge.documentDidChange()
        h.bridge.enterForeground()
        #expect(h.sink.events.isEmpty)
    }
}

extension BridgeEvent {
    var jsonDescription: String {
        let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
