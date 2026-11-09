import SwiftUI

/// The `requestDevice` chooser: matching devices as they are found, with
/// their signal strength.
struct ChooserSheet: View {
    let chooser: DeviceChooser
    let onPick: @MainActor (UUID) -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            List {
                if chooser.devices.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Searching for devices…").foregroundStyle(.secondary)
                    }
                }
                ForEach(chooser.devices) { device in
                    Button {
                        onPick(device.id)
                    } label: {
                        HStack {
                            Text(device.name ?? "Unnamed device")
                            Spacer()
                            Image(systemName: "cellularbars", variableValue: Self.signal(device.rssi))
                            Text("\(device.rssi) dBm").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Choose a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    /// RSSI from -100 dBm (nothing) to -40 dBm (full bars).
    private static func signal(_ rssi: Int) -> Double {
        min(max(Double(rssi + 100) / 60, 0), 1)
    }
}
