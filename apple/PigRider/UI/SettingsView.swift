import SwiftUI

/// The server address, entered at first launch and changed later through a
/// three-finger long press on the page.
struct SettingsView: View {
    let model: AppModel
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.20:8080", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                } header: {
                    Text("Server")
                } footer: {
                    Text(error ?? "The address of your PigRider server: http:// on your home network, otherwise https://.")
                        .foregroundStyle(error == nil ? Color.secondary : Color.red)
                }
                Section {
                    LabeledContent("App version", value: AppVersion.label())
                    LabeledContent("Bluetooth bridge", value: "\(model.bridgeVersion)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.hasServer {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.isShowingSettings = false }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { address = model.settings.serverURL?.absoluteString ?? "" }
        }
    }

    private func save() {
        error = model.saveServer(address)
    }
}
