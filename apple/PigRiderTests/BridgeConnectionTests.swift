import Foundation
import Testing
@testable import PigRider

/// connect/disconnect, epochs and link loss (protocol "Connection state and timing").
@MainActor
struct BridgeConnectionTests {
    let h = BridgeHarness()

    @Test func connectingAnUngrantedDeviceIsNotFound() {
        let replies = h.call(.connect(id: kickrID))
        #expect(replies.errorName == .notFoundError)
        #expect(h.central.connects.isEmpty)
    }

    @Test func aGrantOfAnotherOriginDoesNotCount() {
        h.grant(kickrID, origin: BridgeHarness.otherOrigin)
        #expect(h.call(.connect(id: kickrID)).errorName == .notFoundError)
        #expect(h.call(.disconnect(id: kickrID, epoch: nil)).errorName == .notFoundError)
        #expect(h.central.connects.isEmpty)
    }

    @Test func connectResolvesWithItsEpochOnceTheLinkIsUp() {
        h.grant()
        let replies = h.call(.connect(id: kickrID))
        #expect(h.central.connects == [kickrID])
        #expect(replies.isPending)
        h.bridge.central(didConnect: kickrID)
        #expect(replies.epoch == 1)
    }

    @Test func epochsOnlyGrow() {
        let first = h.connect()
        h.call(.disconnect(id: kickrID, epoch: nil))
        h.bridge.central(didDisconnect: kickrID)
        let second = h.connect()
        #expect(first == 1)
        #expect(second == 2)
    }

    @Test func attemptsShareOneLinkAndEachGetsItsOwnEpoch() {
        h.grant()
        let a = h.call(.connect(id: kickrID))
        let b = h.call(.connect(id: kickrID))
        #expect(h.central.connects == [kickrID])
        h.bridge.central(didConnect: kickrID)
        #expect(a.epoch == 1)
        #expect(b.epoch == 2)
    }

    @Test func eventsCarryTheNewestEpoch() {
        h.grant()
        h.call(.connect(id: kickrID))
        h.call(.connect(id: kickrID))
        h.bridge.central(didConnect: kickrID)
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([1]), error: nil)
        #expect(h.sink.events == [.value(id: kickrID, epoch: 2, key: bikeData, value: Data([1]))])
    }

    @Test func connectWhileConnectedBumpsTheEpochAtOnce() {
        h.connect()
        let replies = h.call(.connect(id: kickrID))
        #expect(replies.epoch == 2)
        #expect(h.central.connects == [kickrID])
    }

    @Test func aFailedConnectRejectsWithNetworkErrorAndNoEvent() {
        h.grant()
        let replies = h.call(.connect(id: kickrID))
        h.bridge.central(didFailToConnect: kickrID)
        #expect(replies.errorName == .networkError)
        #expect(h.sink.events.isEmpty)
    }

    @Test func connectWithBluetoothOffIsANetworkError() {
        h.grant()
        h.central.state = .poweredOff
        #expect(h.call(.connect(id: kickrID)).errorName == .networkError)
        #expect(h.central.connects.isEmpty)
    }

    @Test func aDeviceTheSystemDoesNotKnowIsANetworkError() {
        h.central.known = [:]
        h.grant()
        #expect(h.call(.connect(id: kickrID)).errorName == .networkError)
    }

    @Test func disconnectDuringConnectRejectsTheAttemptAndCancels() {
        h.grant()
        let attempt = h.call(.connect(id: kickrID))
        let disconnect = h.call(.disconnect(id: kickrID, epoch: nil))
        #expect(attempt.errorName == .networkError)
        #expect(disconnect.succeeded)
        #expect(h.central.cancels == [kickrID])
        // CoreBluetooth may still report the cancelled attempt; neither callback revives it.
        h.bridge.central(didConnect: kickrID)
        h.bridge.central(didDisconnect: kickrID)
        #expect(attempt.all.count == 1)
        #expect(h.sink.events.isEmpty)
    }

    @Test func disconnectEmitsDisconnectedWithTheCurrentEpoch() {
        let epoch = h.connect()
        h.call(.disconnect(id: kickrID, epoch: nil))
        #expect(h.central.cancels == [kickrID])
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: epoch!)])
    }

    @Test func ourOwnCancelsCallbackIsNotASecondDisconnect() {
        h.connect()
        h.call(.disconnect(id: kickrID, epoch: nil))
        h.bridge.central(didDisconnect: kickrID)
        #expect(h.sink.events.count == 1)
    }

    @Test func disconnectWithAStaleEpochIsIgnored() {
        h.grant()
        h.call(.connect(id: kickrID))
        h.call(.connect(id: kickrID))
        h.bridge.central(didConnect: kickrID)
        let stale = h.call(.disconnect(id: kickrID, epoch: 1))
        #expect(stale.succeeded)
        #expect(h.central.cancels.isEmpty)
        #expect(h.sink.events.isEmpty)
    }

    @Test func disconnectWithTheNewestEpochCancels() {
        h.connect()
        h.call(.disconnect(id: kickrID, epoch: 1))
        #expect(h.central.cancels == [kickrID])
    }

    @Test func disconnectWithoutAnEpochAlwaysCancels() {
        h.connect()
        h.call(.connect(id: kickrID))
        h.call(.disconnect(id: kickrID, epoch: nil))
        #expect(h.central.cancels == [kickrID])
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 2)])
    }

    @Test func disconnectWhenNotConnectedDoesNothing() {
        h.grant()
        #expect(h.call(.disconnect(id: kickrID, epoch: nil)).succeeded)
        #expect(h.central.cancels.isEmpty)
        #expect(h.sink.events.isEmpty)
    }

    @Test func aDroppedLinkEmitsDisconnectedAndRejectsPendingWork() {
        let epoch = h.connect()
        h.resolve(controlPoint)
        let write = h.write(controlPoint, [0])
        h.bridge.central(didDisconnect: kickrID)
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: epoch!)])
        #expect(write.errorName == .networkError)
        #expect(h.log.suffix(2) == ["event disconnected 1", "reply NetworkError"])
    }

    @Test func reconnectingWhileOurCancelIsOutstandingWorks() {
        h.connect()
        h.call(.disconnect(id: kickrID, epoch: nil))
        let again = h.call(.connect(id: kickrID))
        #expect(h.central.connects == [kickrID, kickrID])
        // CoreBluetooth answers the cancel first, then the new connection.
        h.bridge.central(didDisconnect: kickrID)
        #expect(again.isPending)
        h.bridge.central(didConnect: kickrID)
        #expect(again.epoch == 2)
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 1)])
    }

    @Test func valuesArriveOnlyWhileConnected() {
        h.connect()
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([7]), error: nil)
        h.call(.disconnect(id: kickrID, epoch: nil))
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([8]), error: nil)
        #expect(h.sink.events == [.value(id: kickrID, epoch: 1, key: bikeData, value: Data([7])),
                                  .disconnected(id: kickrID, epoch: 1)])
    }

    @Test func bluetoothTurnedOffEndsEveryConnection() {
        h.connect()
        h.resolve(controlPoint)
        let write = h.write(controlPoint, [0])
        h.central.state = .poweredOff
        h.bridge.centralDidUpdateState()
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 1)])
        #expect(write.errorName == .networkError)
    }
}
