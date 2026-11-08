import Foundation
import Testing
@testable import PigRider

/// requestDevice, getDevices, forget, watches and reportUnsupported.
@MainActor
struct BridgeDeviceTests {
    let h = BridgeHarness()
    let trainerRequest = BridgeCall.requestDevice(
        filters: [RequestFilter(services: [ftms]), RequestFilter(services: [cyclingPower])],
        optionalServices: [ftms, cyclingPower, heartRate])

    @Test func requestDeviceShowsMatchingSightingsInTheChooser() throws {
        let replies = h.call(trainerRequest)
        #expect(h.presenter.presentations == 1)
        #expect(h.central.isScanning)
        h.sighting(kickrID, name: "KICKR CORE 1234", services: [ftms])
        h.sighting(polarID, name: "Polar H10", services: [heartRate])
        let chooser = try #require(h.presenter.chooser)
        #expect(chooser.devices.map(\.id) == [kickrID])
        #expect(replies.isPending)
    }

    @Test func pickingADeviceGrantsItToTheOriginAndRepliesWithIt() {
        let replies = h.call(trainerRequest)
        h.sighting(kickrID, name: "KICKR CORE 1234", services: [ftms])
        h.presenter.pick(kickrID)
        #expect(replies.value == .device(DeviceInfo(id: kickrID, name: "KICKR CORE 1234")))
        let grant = h.grants.grant(origin: BridgeHarness.origin, id: kickrID)
        #expect(grant?.services == [ftms, cyclingPower, heartRate])
        #expect(!h.central.isScanning)
    }

    @Test func cancellingTheChooserIsNotFound() {
        let replies = h.call(trainerRequest)
        h.presenter.pick(nil)
        #expect(replies.error == .noDeviceSelected)
        #expect(!h.central.isScanning)
        #expect(h.grants.devices(for: BridgeHarness.origin).isEmpty)
    }

    @Test func pickingADeviceTheChooserNeverShowedIsNotFound() {
        let replies = h.call(trainerRequest)
        h.presenter.pick(polarID)
        #expect(replies.errorName == .notFoundError)
        #expect(h.grants.grant(origin: BridgeHarness.origin, id: polarID) == nil)
    }

    @Test(arguments: [CentralState.poweredOff, .unauthorized, .unsupported])
    func requestDeviceWithoutBluetoothIsNotFound(_ state: CentralState) {
        h.central.state = state
        let replies = h.call(trainerRequest)
        #expect(replies.errorName == .notFoundError)
        #expect(h.presenter.presentations == 0)
    }

    @Test func requestDeviceBeforeBluetoothIsReadyWaitsForTheScan() {
        h.central.state = .unknown
        let replies = h.call(trainerRequest)
        #expect(h.presenter.presentations == 1)
        #expect(!h.central.isScanning)
        h.central.state = .poweredOn
        h.bridge.centralDidUpdateState()
        #expect(h.central.isScanning)
        #expect(replies.isPending)
    }

    @Test func bluetoothDeniedWhileTheChooserIsOpenClosesIt() {
        h.central.state = .unknown
        let replies = h.call(trainerRequest)
        h.central.state = .unauthorized
        h.bridge.centralDidUpdateState()
        #expect(replies.errorName == .notFoundError)
        #expect(h.presenter.dismissals == 1)
    }

    @Test func aSecondRequestWhileTheChooserIsOpenIsRefused() {
        let first = h.call(trainerRequest)
        let second = h.call(trainerRequest)
        #expect(second.errorName == .invalidStateError)
        #expect(first.isPending)
    }

    @Test func getDevicesListsOnlyTheCallingOriginsGrants() {
        h.grant(kickrID)
        h.grant(polarID, services: [heartRate], origin: BridgeHarness.otherOrigin)
        #expect(h.call(.getDevices).value == .devices([DeviceInfo(id: kickrID, name: "KICKR CORE 1234")]))
        #expect(h.call(.getDevices, origin: BridgeHarness.otherOrigin).value == .devices([DeviceInfo(id: polarID, name: "Polar H10")]))
    }

    @Test func forgetDropsTheGrantAndDisconnects() {
        let epoch = h.connect()
        let replies = h.call(.forget(id: kickrID))
        #expect(replies.value == ReplyValue.none)
        #expect(h.grants.grant(origin: BridgeHarness.origin, id: kickrID) == nil)
        #expect(h.central.cancels == [kickrID])
        #expect(h.sink.events == [.disconnected(id: kickrID, epoch: epoch!)])
    }

    @Test func forgetFromAnotherOriginLeavesTheGrant() {
        h.grant(kickrID)
        #expect(h.call(.forget(id: kickrID), origin: BridgeHarness.otherOrigin).succeeded)
        #expect(h.grants.grant(origin: BridgeHarness.origin, id: kickrID) != nil)
    }

    @Test func watchingAnUngrantedDeviceIsNotFound() {
        let replies = h.call(.watchAdvertisements(id: kickrID, watchId: "w1"))
        #expect(replies.errorName == .notFoundError)
        #expect(!h.central.isScanning)
    }

    @Test func aWatchReportsSightingsOfItsDeviceOnly() {
        h.grant(kickrID)
        let replies = h.call(.watchAdvertisements(id: kickrID, watchId: "w1"))
        #expect(replies.succeeded)
        #expect(h.central.isScanning)
        h.sighting(polarID, name: "Polar H10")
        h.sighting(kickrID, name: "KICKR CORE 1234", rssi: -61)
        #expect(h.sink.events == [.advertisement(watchId: "w1", id: kickrID, name: "KICKR CORE 1234", rssi: -61)])
    }

    @Test func unwatchingStopsTheScanWhenNothingElseWatches() {
        h.grant(kickrID)
        h.grant(polarID, services: [heartRate])
        h.call(.watchAdvertisements(id: kickrID, watchId: "w1"))
        h.call(.watchAdvertisements(id: polarID, watchId: "w2"))
        #expect(h.call(.unwatchAdvertisements(watchId: "w1")).succeeded)
        #expect(h.central.isScanning)
        h.sighting(kickrID, name: "KICKR")
        #expect(h.sink.events.isEmpty)
        h.call(.unwatchAdvertisements(watchId: "w2"))
        #expect(!h.central.isScanning)
    }

    @Test func unwatchingAnUnknownWatchIsHarmless() {
        #expect(h.call(.unwatchAdvertisements(watchId: "nope")).succeeded)
    }

    @Test func forgetEndsTheDevicesWatches() {
        h.grant(kickrID)
        h.call(.watchAdvertisements(id: kickrID, watchId: "w1"))
        h.call(.forget(id: kickrID))
        #expect(!h.central.isScanning)
    }

    @Test func theChooserAndAWatchShareOneScan() {
        h.grant(kickrID)
        h.call(.watchAdvertisements(id: kickrID, watchId: "w1"))
        h.call(trainerRequest)
        h.sighting(kickrID, name: "KICKR CORE 1234", services: [ftms])
        #expect(h.sink.events.count == 1)
        #expect(h.presenter.chooser?.devices.count == 1)
        h.presenter.pick(nil)
        #expect(h.central.isScanning)
    }

    @Test func reportUnsupportedShowsTheBanner() {
        #expect(h.call(.reportUnsupported(method: "getAvailability")).succeeded)
        #expect(h.unsupported.methods == ["getAvailability"])
    }
}
