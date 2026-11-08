import Foundation
import Testing
@testable import PigRider

/// GATT operations: grant checks, discovery cache, property checks, FIFOs,
/// timeouts and fencing (protocol "GATT operations and timeouts").
@MainActor
struct BridgeGattTests {
    let h = BridgeHarness()

    // MARK: Grants and connection

    @Test func aServiceOutsideTheGrantIsASecurityErrorWithoutTouchingTheDevice() {
        h.grant(kickrID, services: [ftms])
        h.connect()
        let replies = h.call(.getPrimaryService(id: kickrID, service: cyclingPower))
        #expect(replies.error == .serviceNotAllowed)
        #expect(h.call(.startNotifications(id: kickrID, key: powerMeasurement)).error == .serviceNotAllowed)
        #expect(h.kickr.calls.isEmpty)
    }

    @Test func gattCallsFromAnotherOriginAreNotFound() {
        h.connect()
        let replies = h.call(.getPrimaryService(id: kickrID, service: ftms), origin: BridgeHarness.otherOrigin)
        #expect(replies.errorName == .notFoundError)
        #expect(h.kickr.calls.isEmpty)
    }

    @Test func gattCallsWhileDisconnectedAreNetworkErrors() {
        h.grant()
        #expect(h.call(.getPrimaryService(id: kickrID, service: ftms)).error == .gattDisconnected)
        #expect(h.write(controlPoint, [0]).error == .gattDisconnected)
    }

    // MARK: Discovery

    @Test func getPrimaryServiceDiscoversAndAnswers() {
        h.connect()
        let replies = h.call(.getPrimaryService(id: kickrID, service: ftms))
        #expect(h.kickr.calls == [.discoverServices])
        #expect(replies.isPending)
        h.answerDiscoveries()
        #expect(replies.value == ReplyValue.none)
    }

    @Test func anAbsentServiceIsNotFound() {
        h.grant(kickrID, services: [ftms, heartRate])
        h.connect()
        let replies = h.call(.getPrimaryService(id: kickrID, service: heartRate))
        h.answerDiscoveries()
        #expect(replies.error == .serviceNotFound)
    }

    @Test func getCharacteristicReturnsItsProperties() {
        h.connect()
        let replies = h.call(.getCharacteristic(id: kickrID, key: controlPoint))
        h.answerDiscoveries()
        #expect(replies.value == .properties([.write, .indicate]))
        #expect(h.kickr.calls == [.discoverServices, .discoverCharacteristics(ftms)])
    }

    @Test func anAbsentCharacteristicIsNotFound() {
        h.connect()
        let replies = h.call(.getCharacteristic(id: kickrID, service: ftms, characteristic: uuid("2aff")))
        h.answerDiscoveries()
        #expect(replies.error == .characteristicNotFound)
    }

    @Test func discoveryIsCachedPerConnection() {
        h.connect()
        h.resolve(controlPoint)
        h.call(.getPrimaryService(id: kickrID, service: ftms))
        let second = h.call(.getCharacteristic(id: kickrID, key: bikeData))
        #expect(second.value == .properties([.notify]))
        #expect(h.kickr.discoveries.count == 2)
    }

    @Test func concurrentLookupsShareOneDiscovery() {
        h.connect()
        let a = h.call(.getPrimaryService(id: kickrID, service: ftms))
        let b = h.call(.getCharacteristic(id: kickrID, key: controlPoint))
        let c = h.call(.getCharacteristic(id: kickrID, key: bikeData))
        h.answerDiscoveries()
        #expect(a.succeeded && b.succeeded && c.succeeded)
        #expect(h.kickr.discoveries == [.discoverServices, .discoverCharacteristics(ftms)])
    }

    @Test func aNewConnectionDiscoversAgain() {
        h.connect()
        h.resolve(controlPoint)
        h.call(.disconnect(id: kickrID, epoch: nil))
        h.bridge.central(didDisconnect: kickrID)
        h.connect()
        h.resolve(controlPoint)
        #expect(h.kickr.discoveries.count == 4)
    }

    @Test func aFailedDiscoveryRejectsAndIsRetriedNextTime() {
        h.connect()
        let first = h.call(.getPrimaryService(id: kickrID, service: ftms))
        h.bridge.peripheral(kickrID, didDiscoverServices: [], error: BridgeError(.networkError, "boom"))
        #expect(first.errorName == .networkError)
        let second = h.call(.getPrimaryService(id: kickrID, service: ftms))
        h.answerDiscoveries()
        #expect(second.succeeded)
    }

    @Test func operationsDiscoverOnDemand() {
        h.connect()
        let write = h.write(controlPoint, [1])
        h.answerDiscoveries()
        #expect(h.kickr.writes == [.write(Data([1]), controlPoint, withResponse: true)])
        #expect(write.isPending)
    }

    // MARK: Property checks

    @Test func writeWithResponseNeedsTheWriteProperty() {
        h.connect()
        h.resolve(bikeData)
        let replies = h.write(bikeData, [1], withResponse: true)
        #expect(replies.errorName == .notSupportedError)
        #expect(h.kickr.writes.isEmpty)
    }

    @Test func writeWithoutResponseNeedsItsProperty() {
        h.connect()
        h.resolve(controlPoint)
        let replies = h.write(controlPoint, [1], withResponse: false)
        #expect(replies.errorName == .notSupportedError)
        #expect(h.kickr.writes.isEmpty)
    }

    @Test func notificationsNeedNotifyOrIndicate() {
        h.connect()
        h.resolve(controlPoint)
        h.resolve(commandChannel)
        #expect(h.call(.startNotifications(id: kickrID, key: controlPoint)).isPending) // indicate
        #expect(h.call(.startNotifications(id: kickrID, key: commandChannel)).isPending) // notify
        let noNotify = CharacteristicKey(service: cyclingPower, characteristic: uuid("2a65"))
        h.kickr.gatt[1].characteristics.append(DiscoveredCharacteristic(uuid: noNotify.characteristic, properties: [.read]))
        h.resolve(noNotify)
        let callsBefore = h.kickr.calls.count
        #expect(h.call(.startNotifications(id: kickrID, key: noNotify)).errorName == .notSupportedError)
        #expect(h.kickr.calls.count == callsBefore)
    }

    // MARK: Notifications and writes

    @Test func startNotificationsResolvesOnTheStateCallback() {
        h.connect()
        h.resolve(bikeData)
        let replies = h.call(.startNotifications(id: kickrID, key: bikeData))
        #expect(h.kickr.calls.last == .setNotify(bikeData))
        #expect(replies.isPending)
        h.bridge.peripheral(kickrID, didUpdateNotificationStateFor: bikeData, error: nil)
        #expect(replies.succeeded)
    }

    @Test func aWriteWithResponseResolvesOnItsCallback() {
        h.connect()
        h.resolve(controlPoint)
        let replies = h.write(controlPoint, [0x00])
        #expect(h.kickr.writes == [.write(Data([0]), controlPoint, withResponse: true)])
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil)
        #expect(replies.succeeded)
    }

    @Test func aWriteErrorIsPassedOn() {
        h.connect()
        h.resolve(controlPoint)
        let replies = h.write(controlPoint, [0x00])
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: BridgeError(.notSupportedError, "GATT operation not permitted."))
        #expect(replies.errorName == .notSupportedError)
    }

    @Test func operationsOnOneCharacteristicRunOneAtATimeInOrder() {
        h.connect()
        h.resolve(controlPoint)
        let a = h.write(controlPoint, [1])
        let b = h.write(controlPoint, [2])
        #expect(h.kickr.writes == [.write(Data([1]), controlPoint, withResponse: true)])
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil)
        #expect(a.succeeded)
        #expect(b.isPending)
        #expect(h.kickr.writes.last == .write(Data([2]), controlPoint, withResponse: true))
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil)
        #expect(b.succeeded)
    }

    @Test func differentCharacteristicsDoNotWaitForEachOther() {
        h.connect()
        h.resolve(controlPoint)
        h.resolve(bikeData)
        h.write(controlPoint, [1])
        h.call(.startNotifications(id: kickrID, key: bikeData))
        #expect(h.kickr.calls.suffix(2) == [.write(Data([1]), controlPoint, withResponse: true), .setNotify(bikeData)])
    }

    @Test func aCallbackOfAnotherKindDoesNotCompleteTheHead() {
        h.connect()
        h.resolve(controlPoint)
        let write = h.write(controlPoint, [1])
        h.bridge.peripheral(kickrID, didUpdateNotificationStateFor: controlPoint, error: nil)
        #expect(write.isPending)
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil)
        #expect(write.succeeded)
    }

    @Test func aStrayCallbackWithNothingPendingIsDropped() {
        h.connect()
        h.resolve(controlPoint)
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil)
        let write = h.write(controlPoint, [1])
        #expect(write.isPending)
    }

    // MARK: Write without response

    @Test func writeWithoutResponseResolvesOnceHandedOver() {
        h.connect()
        h.resolve(commandChannel)
        let replies = h.write(commandChannel, [9], withResponse: false)
        #expect(h.kickr.writes == [.write(Data([9]), commandChannel, withResponse: false)])
        #expect(replies.succeeded)
    }

    @Test func writeWithoutResponseWaitsUntilThePeripheralIsReady() {
        h.connect()
        h.resolve(commandChannel)
        h.kickr.canSendWriteWithoutResponse = false
        let a = h.write(commandChannel, [1], withResponse: false)
        let b = h.write(commandChannel, [2], withResponse: false)
        #expect(h.kickr.writes.isEmpty)
        #expect(a.isPending)
        h.kickr.canSendWriteWithoutResponse = true
        h.bridge.peripheralIsReadyToSendWriteWithoutResponse(kickrID)
        #expect(h.kickr.writes == [.write(Data([1]), commandChannel, withResponse: false),
                                   .write(Data([2]), commandChannel, withResponse: false)])
        #expect(a.succeeded && b.succeeded)
    }

    @Test func writeWithoutResponseWaitingTooLongEndsTheConnection() {
        h.connect()
        h.resolve(commandChannel)
        h.kickr.canSendWriteWithoutResponse = false
        let write = h.write(commandChannel, [1], withResponse: false)
        h.scheduler.advance(by: .seconds(10))
        #expect(write.errorName == .networkError)
        #expect(h.central.cancels == [kickrID])
    }

    // MARK: Timeouts and fencing

    @Test func noTimeoutFiresForAnOperationThatCompleted() {
        h.connect()
        h.resolve(controlPoint)
        h.write(controlPoint, [1])
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil)
        h.scheduler.advance(by: .seconds(30))
        #expect(h.central.cancels.isEmpty)
        #expect(h.sink.events.isEmpty)
        #expect(h.scheduler.pendingCount == 0)
    }

    @Test func aTimeoutCancelsTheConnectionRejectsEverythingAndEmitsDisconnected() {
        let epoch = h.connect()
        h.resolve(controlPoint)
        h.resolve(bikeData)
        let a = h.write(controlPoint, [1])
        let queued = h.write(controlPoint, [2])
        let notify = h.call(.startNotifications(id: kickrID, key: bikeData))
        h.scheduler.advance(by: .seconds(9))
        #expect(a.isPending)
        h.scheduler.advance(by: .seconds(1))
        #expect(h.central.cancels == [kickrID])
        #expect(a.errorName == .networkError)
        #expect(queued.errorName == .networkError)
        #expect(notify.errorName == .networkError)
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: epoch!)])
        #expect(h.log.suffix(4).first == "event disconnected 1")
    }

    @Test func aDiscoveryTimeoutEndsTheConnectionToo() {
        h.connect()
        let replies = h.call(.getPrimaryService(id: kickrID, service: ftms))
        h.scheduler.advance(by: .seconds(10))
        #expect(replies.errorName == .networkError)
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 1)])
    }

    @Test func aLateCallbackAfterATimeoutNeverResolvesTheNextWrite() {
        h.connect()
        h.resolve(controlPoint)
        let a = h.write(controlPoint, [1])
        h.scheduler.advance(by: .seconds(10))
        let b = h.write(controlPoint, [2])
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil) // A, late
        #expect(a.all == [.failure(.timedOut)])
        #expect(b.all == [.failure(.gattDisconnected)])
    }

    @Test func aLateCallbackBeforeTheReconnectIsDroppedAndTheNewWriteWaitsForItsOwn() {
        h.connect()
        h.resolve(controlPoint)
        let a = h.write(controlPoint, [1])
        h.scheduler.advance(by: .seconds(10))
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil) // A, late
        h.bridge.central(didDisconnect: kickrID) // answer to the timeout's cancel
        let epoch = h.connect()
        let b = h.write(controlPoint, [2])
        h.answerDiscoveries()
        #expect(epoch == 2)
        #expect(a.all == [.failure(.timedOut)])
        #expect(b.isPending)
        #expect(h.kickr.writes.last == .write(Data([2]), controlPoint, withResponse: true))
        h.bridge.peripheral(kickrID, didWriteValueFor: controlPoint, error: nil)
        #expect(b.succeeded)
    }

    @Test func aTimeoutOfAnOldConnectionDoesNotTouchANewOne() {
        h.connect()
        h.resolve(controlPoint)
        h.write(controlPoint, [1])
        h.bridge.central(didDisconnect: kickrID) // link dropped
        h.connect()
        h.scheduler.advance(by: .seconds(10))
        #expect(h.central.cancels.isEmpty)
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: 1)])
    }
}
