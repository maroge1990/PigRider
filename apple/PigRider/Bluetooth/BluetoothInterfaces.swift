import Foundation

// The seams between `BluetoothBridge` and the OS. CoreBluetooth sits behind
// `CentralManaging`/`PeripheralHandle` (real adapters in
// CoreBluetoothAdapters.swift), so tests drive the bridge with fakes.

enum CentralState: Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

/// `CBCentralManager`, reduced to what the bridge uses.
@MainActor
protocol CentralManaging: Scanning {
    var state: CentralState { get }
    /// Receives CoreBluetooth's callbacks. Held weakly.
    var delegate: (any CentralEvents)? { get set }
    func connect(_ peripheral: any PeripheralHandle)
    func cancelConnection(_ peripheral: any PeripheralHandle)
    /// A peripheral known to the system (`retrievePeripherals(withIdentifiers:)`).
    func retrievePeripheral(withIdentifier id: UUID) -> (any PeripheralHandle)?
}

extension CentralManaging {
    var canScan: Bool { state == .poweredOn }
}

/// A discovered characteristic of a service.
struct DiscoveredCharacteristic: Equatable, Sendable {
    let uuid: BluetoothUUID
    let properties: CharacteristicProperties
}

/// `CBPeripheral`, addressed by UUIDs instead of `CBService`/`CBCharacteristic`.
/// Results arrive through `CentralEvents`.
@MainActor
protocol PeripheralHandle: AnyObject {
    var identifier: UUID { get }
    var name: String? { get }
    var canSendWriteWithoutResponse: Bool { get }
    func discoverServices()
    func discoverCharacteristics(for service: BluetoothUUID)
    func setNotifyValue(_ enabled: Bool, for key: CharacteristicKey)
    func writeValue(_ value: Data, for key: CharacteristicKey, withResponse: Bool)
}

/// CoreBluetooth's delegate callbacks, forwarded by the adapters. Errors are
/// already mapped to the `DOMException` the page should see.
@MainActor
protocol CentralEvents: AnyObject {
    func centralDidUpdateState()
    func central(didDiscover peripheral: any PeripheralHandle, advertisement: Advertisement)
    func central(didConnect id: UUID)
    func central(didFailToConnect id: UUID)
    func central(didDisconnect id: UUID)
    func peripheral(_ id: UUID, didDiscoverServices services: [BluetoothUUID], error: BridgeError?)
    func peripheral(_ id: UUID, didDiscoverCharacteristics characteristics: [DiscoveredCharacteristic],
                    for service: BluetoothUUID, error: BridgeError?)
    func peripheral(_ id: UUID, didUpdateNotificationStateFor key: CharacteristicKey, error: BridgeError?)
    func peripheral(_ id: UUID, didWriteValueFor key: CharacteristicKey, error: BridgeError?)
    func peripheral(_ id: UUID, didUpdateValueFor key: CharacteristicKey, value: Data?, error: BridgeError?)
    func peripheralIsReadyToSendWriteWithoutResponse(_ id: UUID)
}

/// Sends protocol events to the page (`callAsyncJavaScript` in the app).
@MainActor
protocol EventSink: AnyObject {
    func send(_ event: BridgeEvent)
}

/// Shows the device chooser for `requestDevice`. The completion gets the
/// picked device id, or nil if the user cancelled; `dismiss` closes it
/// without calling the completion.
@MainActor
protocol ChooserPresenting: AnyObject {
    func present(_ chooser: DeviceChooser, completion: @escaping @MainActor (UUID?) -> Void)
    func dismiss(_ chooser: DeviceChooser)
}

@MainActor
protocol TimerToken {
    func cancel()
}

/// Runs an action after a delay on the main actor; injected so tests control time.
@MainActor
protocol Scheduling {
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any TimerToken
}

/// `Scheduling` on Swift concurrency's clock, for the app.
struct TaskScheduler: Scheduling {
    private struct Token: TimerToken {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any TimerToken {
        Token(task: Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        })
    }
}
