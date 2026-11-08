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
        #expect(h.central.connects == [kickrID])
        // The new attempt waits for CoreBluetooth's answer to the cancel.
        h.bridge.central(didDisconnect: kickrID)
        #expect(h.central.connects == [kickrID, kickrID])
        #expect(again.isPending)
        h.bridge.central(didConnect: kickrID)
        #expect(again.epoch == 2)
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 1)])
    }

    // MARK: Draining a cancel

    @Test func aCancelledAttemptsLateCallbacksNeverReachANewerAttempt() {
        h.grant()
        let old = h.call(.connect(id: kickrID))
        h.call(.disconnect(id: kickrID, epoch: nil))
        let new = h.call(.connect(id: kickrID))
        #expect(h.central.connects == [kickrID])
        // The cancelled attempt's link came up anyway, and its callbacks follow.
        h.bridge.central(didConnect: kickrID)
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([1]), error: nil)
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil)
        h.bridge.peripheral(kickrID, didDiscoverServices: [ftms], error: nil)
        #expect(new.isPending)
        #expect(h.call(.getPrimaryService(id: kickrID, service: ftms)).errorName == .networkError)
        // CoreBluetooth's answer to the cancel; only now does the new attempt start.
        h.bridge.central(didDisconnect: kickrID)
        #expect(h.central.connects == [kickrID, kickrID])
        #expect(new.isPending)
        h.bridge.central(didConnect: kickrID)
        #expect(new.epoch == 2)
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([2]), error: nil)
        h.resolve(controlPoint)
        #expect(old.errorName == .networkError)
        #expect(h.sink.events == [.value(id: kickrID, epoch: 2, key: bikeData, value: Data([2]))])
    }

    @Test func connectsQueuedWhileDrainingEachReplyWithTheirOwnEpoch() {
        h.connect()
        h.call(.disconnect(id: kickrID, epoch: nil))
        let a = h.call(.connect(id: kickrID))
        let b = h.call(.connect(id: kickrID))
        h.bridge.central(didDisconnect: kickrID)
        #expect(h.central.connects == [kickrID, kickrID])
        h.bridge.central(didConnect: kickrID)
        #expect(a.epoch == 2)
        #expect(b.epoch == 3)
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 1)])
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func didFailToConnectAlsoEndsTheDrain() {
        h.grant()
        h.call(.connect(id: kickrID))
        h.call(.disconnect(id: kickrID, epoch: nil))
        let new = h.call(.connect(id: kickrID))
        h.bridge.central(didFailToConnect: kickrID)
        #expect(h.central.connects == [kickrID, kickrID])
        #expect(new.isPending)
        h.bridge.central(didConnect: kickrID)
        #expect(new.epoch == 2)
    }

    @Test func anUnansweredCancelOfALinkTheSystemHasDroppedEndsTheDrainAtTheTimeout() {
        h.grant()
        h.call(.connect(id: kickrID))
        h.call(.disconnect(id: kickrID, epoch: nil))
        let new = h.call(.connect(id: kickrID))
        h.kickr.state = .disconnected
        h.scheduler.advance(by: BluetoothBridge.drainTimeout - .milliseconds(1))
        #expect(h.central.connects == [kickrID])
        h.scheduler.advance(by: .milliseconds(1))
        // CoreBluetooth no longer holds the old link, so the next didConnect is the new attempt's.
        #expect(h.central.connects == [kickrID, kickrID])
        #expect(h.central.cancels == [kickrID])
        h.bridge.central(didConnect: kickrID)
        #expect(new.epoch == 2)
    }

    @Test(arguments: [PeripheralState.connecting, .connected, .disconnecting])
    func aTimeoutNeverEndsTheDrainWhileTheSystemStillHoldsTheOldLink(_ state: PeripheralState) {
        h.grant()
        let old = h.call(.connect(id: kickrID))
        h.call(.disconnect(id: kickrID, epoch: nil))
        let queued = h.call(.connect(id: kickrID))
        h.kickr.state = state
        h.scheduler.advance(by: BluetoothBridge.drainTimeout)
        #expect(queued.errorName == .networkError)
        #expect(h.central.cancels == [kickrID, kickrID])
        #expect(h.central.connects == [kickrID])
        // The old attempt's late link and its callbacks still reach nothing.
        h.bridge.central(didConnect: kickrID)
        h.bridge.peripheral(kickrID, didDiscoverServices: [ftms], error: nil)
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([1]), error: nil)
        #expect(h.call(.getPrimaryService(id: kickrID, service: ftms)).errorName == .networkError)
        #expect(old.all.count == 1)
        #expect(queued.all.count == 1)
        #expect(h.sink.events.isEmpty)
        // Once CoreBluetooth lets go, the next connect is clean, with a newer epoch.
        h.bridge.central(didDisconnect: kickrID)
        h.kickr.state = .disconnected
        let next = h.call(.connect(id: kickrID))
        #expect(h.central.connects == [kickrID, kickrID])
        h.bridge.central(didConnect: kickrID)
        h.bridge.peripheral(kickrID, didUpdateValueFor: bikeData, value: Data([2]), error: nil)
        h.resolve(controlPoint)
        #expect(next.epoch == 3)
        #expect(h.sink.events == [.value(id: kickrID, epoch: 3, key: bikeData, value: Data([2]))])
    }

    @Test func aConnectAfterAnExpiredDrainIsRejectedWhileTheSystemStillHoldsTheOldLink() {
        h.grant()
        h.call(.connect(id: kickrID))
        h.call(.disconnect(id: kickrID, epoch: nil))
        h.kickr.state = .connected
        h.scheduler.advance(by: BluetoothBridge.drainTimeout)
        let pendingTimers = h.scheduler.pendingCount
        let refused = h.call(.connect(id: kickrID))
        #expect(refused.errorName == .networkError)
        #expect(h.central.connects == [kickrID])
        #expect(h.scheduler.pendingCount == pendingTimers)
        // The system lets go without telling us; the next connect sees it and goes ahead.
        h.kickr.state = .disconnected
        let next = h.call(.connect(id: kickrID))
        #expect(h.central.connects == [kickrID, kickrID])
        h.bridge.central(didConnect: kickrID)
        #expect(next.succeeded)
    }

    @Test func anAnsweredDrainsTimeoutDoesNotEndTheNextDrain() {
        h.connect()
        h.call(.disconnect(id: kickrID, epoch: nil))
        h.scheduler.advance(by: .seconds(1))
        h.bridge.central(didDisconnect: kickrID)
        h.connect()
        h.call(.disconnect(id: kickrID, epoch: nil))
        let queued = h.call(.connect(id: kickrID))
        // Past the first drain's deadline, before the second's.
        h.scheduler.advance(by: BluetoothBridge.drainTimeout - .milliseconds(500))
        #expect(h.central.connects.count == 2)
        #expect(queued.isPending)
    }

    @Test func aDisconnectWhileDrainingRejectsTheQueuedAttemptOnly() {
        h.connect()
        h.call(.disconnect(id: kickrID, epoch: nil))
        let queued = h.call(.connect(id: kickrID))
        let disconnect = h.call(.disconnect(id: kickrID, epoch: 2))
        #expect(queued.errorName == .networkError)
        #expect(disconnect.succeeded)
        #expect(h.central.cancels == [kickrID])
        h.bridge.central(didDisconnect: kickrID)
        #expect(h.central.connects == [kickrID])
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 1)])
    }

    @Test func bluetoothTurnedOffWhileDrainingRejectsTheQueuedAttempt() {
        h.connect()
        h.call(.disconnect(id: kickrID, epoch: nil))
        let queued = h.call(.connect(id: kickrID))
        h.central.state = .poweredOff
        h.bridge.centralDidUpdateState()
        #expect(queued.errorName == .networkError)
        // CoreBluetooth answers no cancel once it is off, so a connect afterwards starts at once.
        h.central.state = .poweredOn
        h.bridge.centralDidUpdateState()
        h.call(.connect(id: kickrID))
        #expect(h.central.connects == [kickrID, kickrID])
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
