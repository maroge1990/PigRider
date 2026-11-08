import Foundation
import Testing
@testable import PigRider

@MainActor
final class FakeScanner: Scanning {
    var canScan = true
    var isScanning = false
    var starts = 0
    var stops = 0

    func startScan() {
        starts += 1
        isScanning = true
    }

    func stopScan() {
        stops += 1
        isScanning = false
    }
}

@MainActor
struct ScanCoordinatorTests {
    let scanner = FakeScanner()
    let coordinator: ScanCoordinator

    init() {
        coordinator = ScanCoordinator(scanner: scanner)
    }

    func sighting(_ name: String) -> Advertisement {
        Advertisement(id: kickrID, name: name, services: [], manufacturerCompanyIdentifiers: [], rssi: -50)
    }

    @Test func noScanWithoutConsumers() {
        #expect(!scanner.isScanning)
        #expect(scanner.starts == 0)
    }

    @Test func oneScanServesManyConsumers() {
        var seen: [String] = []
        _ = coordinator.addConsumer { seen.append("a:" + ($0.name ?? "")) }
        _ = coordinator.addConsumer { seen.append("b:" + ($0.name ?? "")) }
        #expect(scanner.starts == 1)
        coordinator.deliver(sighting("x"))
        #expect(seen == ["a:x", "b:x"])
    }

    @Test func removingOneConsumerKeepsTheOthersAndTheScan() {
        var seen: [String] = []
        let a = coordinator.addConsumer { _ in seen.append("a") }
        _ = coordinator.addConsumer { _ in seen.append("b") }
        coordinator.removeConsumer(a)
        coordinator.deliver(sighting("x"))
        #expect(seen == ["b"])
        #expect(scanner.isScanning)
    }

    @Test func theScanStopsAtZeroConsumers() {
        let a = coordinator.addConsumer { _ in }
        let b = coordinator.addConsumer { _ in }
        coordinator.removeConsumer(a)
        coordinator.removeConsumer(b)
        #expect(!scanner.isScanning)
        #expect(scanner.stops == 1)
    }

    @Test func aConsumerMayRemoveItselfOnItsFirstSighting() {
        final class Holder { var token: ScanCoordinator.Token? }
        let holder = Holder()
        var seen = 0
        holder.token = coordinator.addConsumer { _ in
            seen += 1
            if let token = holder.token { coordinator.removeConsumer(token) }
        }
        coordinator.deliver(sighting("x"))
        coordinator.deliver(sighting("x"))
        #expect(seen == 1)
        #expect(!scanner.isScanning)
    }

    @Test func pauseStopsTheScanButKeepsConsumers() {
        var seen = 0
        _ = coordinator.addConsumer { _ in seen += 1 }
        coordinator.pause()
        #expect(!scanner.isScanning)
        #expect(coordinator.consumerCount == 1)
        coordinator.deliver(sighting("late"))
        #expect(seen == 0)
    }

    @Test func resumeRestartsTheScanForRemainingConsumers() {
        var seen: [String] = []
        let a = coordinator.addConsumer { _ in seen.append("a") }
        _ = coordinator.addConsumer { _ in seen.append("b") }
        coordinator.pause()
        coordinator.removeConsumer(a)
        #expect(!scanner.isScanning)
        coordinator.resume()
        #expect(scanner.isScanning)
        coordinator.deliver(sighting("x"))
        #expect(seen == ["b"])
    }

    @Test func resumeWithoutConsumersDoesNotScan() {
        let a = coordinator.addConsumer { _ in }
        coordinator.pause()
        coordinator.removeConsumer(a)
        coordinator.resume()
        #expect(!scanner.isScanning)
    }

    @Test func addingAConsumerWhilePausedWaitsForResume() {
        coordinator.pause()
        _ = coordinator.addConsumer { _ in }
        #expect(!scanner.isScanning)
        coordinator.resume()
        #expect(scanner.isScanning)
    }

    @Test func removeAllDropsEveryConsumerAndStops() {
        var seen = 0
        _ = coordinator.addConsumer { _ in seen += 1 }
        _ = coordinator.addConsumer { _ in seen += 1 }
        coordinator.removeAll()
        #expect(coordinator.consumerCount == 0)
        #expect(!scanner.isScanning)
        coordinator.deliver(sighting("x"))
        #expect(seen == 0)
    }

    @Test func theScanWaitsUntilBluetoothIsAvailable() {
        scanner.canScan = false
        _ = coordinator.addConsumer { _ in }
        #expect(!scanner.isScanning)
        scanner.canScan = true
        coordinator.availabilityChanged()
        #expect(scanner.isScanning)
    }

    @Test func losingBluetoothForgetsTheScanWithoutStoppingIt() {
        _ = coordinator.addConsumer { _ in }
        scanner.canScan = false
        coordinator.availabilityChanged()
        #expect(scanner.stops == 0)
        scanner.canScan = true
        coordinator.availabilityChanged()
        #expect(scanner.starts == 2)
    }
}
