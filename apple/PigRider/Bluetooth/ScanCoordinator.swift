import Foundation

/// The part of the central that scans. Scans run with no service filter and
/// duplicates allowed; consumers filter in the app.
@MainActor
protocol Scanning: AnyObject {
    /// Whether a scan can run now (Bluetooth powered on).
    var canScan: Bool { get }
    func startScan()
    func stopScan()
}

/// Owns the one scan. Consumers are the chooser and each
/// `watchAdvertisements` subscription; the scan runs while at least one is
/// left, Bluetooth is available and the app is not paused (in background).
@MainActor
final class ScanCoordinator {
    struct Token: Hashable, Sendable {
        fileprivate let raw: Int
    }

    typealias Consumer = @MainActor (Advertisement) -> Void

    private let scanner: any Scanning
    private var consumers: [(token: Token, handler: Consumer)] = []
    private var nextToken = 0
    private var paused = false
    private(set) var isScanning = false

    init(scanner: any Scanning) {
        self.scanner = scanner
    }

    var consumerCount: Int { consumers.count }

    func addConsumer(_ handler: @escaping Consumer) -> Token {
        nextToken += 1
        let token = Token(raw: nextToken)
        consumers.append((token, handler))
        update()
        return token
    }

    func removeConsumer(_ token: Token) {
        consumers.removeAll { $0.token == token }
        update()
    }

    /// Document generation bump: every consumer goes.
    func removeAll() {
        consumers.removeAll()
        update()
    }

    /// App in background: stop scanning, keep the consumers.
    func pause() {
        paused = true
        update()
    }

    func resume() {
        paused = false
        update()
    }

    /// Bluetooth state changed. When it went away, CoreBluetooth has already
    /// stopped the scan, so only the bookkeeping changes.
    func availabilityChanged() {
        if !scanner.canScan { isScanning = false }
        update()
    }

    /// One sighting from the central, given to every consumer still registered.
    func deliver(_ ad: Advertisement) {
        guard isScanning else { return }
        for (token, handler) in consumers where consumers.contains(where: { $0.token == token }) {
            handler(ad)
        }
    }

    private func update() {
        let wanted = !paused && !consumers.isEmpty && scanner.canScan
        guard wanted != isScanning else { return }
        isScanning = wanted
        if wanted { scanner.startScan() } else { scanner.stopScan() }
    }
}
