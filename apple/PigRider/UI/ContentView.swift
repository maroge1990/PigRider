import SwiftUI

/// The page full screen, with the native pieces on top: the unsupported-API
/// banner, a load failure, the device chooser and settings.
struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        WebViewContainer(webView: model.shell.webView) { model.isShowingSettings = true }
            .ignoresSafeArea()
            .overlay {
                if let failure = model.shell.status.loadFailure {
                    LoadFailureView(message: failure, retry: { model.shell.retry() }) { model.isShowingSettings = true }
                }
            }
            .overlay(alignment: .top) {
                if let member = model.shell.status.unsupportedMember {
                    UnsupportedBanner(member: member) { model.shell.status.unsupportedMember = nil }
                }
            }
            .sheet(item: chooserRequest) { request in
                ChooserSheet(chooser: request.chooser, onPick: { model.chooser.pick($0) },
                             onCancel: { model.chooser.pick(nil) })
                    .interactiveDismissDisabled()
                    .onDisappear { model.chooser.sheetClosed(request.id) }
            }
            .sheet(isPresented: $model.isShowingSettings) {
                SettingsView(model: model)
                    .interactiveDismissDisabled(!model.hasServer)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                model.scenePhaseChanged(phase)
            }
    }

    /// Driven by the presenter only: the sheet closes through `pick`, `dismiss` or `sheetClosed`.
    private var chooserRequest: Binding<ChooserPresenter.Request?> {
        Binding(get: { model.chooser.request }, set: { _ in })
    }
}

/// "This server needs a newer PigRider app": the page asked for a Web
/// Bluetooth member the bridge does not provide.
struct UnsupportedBanner: View {
    let member: String
    let close: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("This server needs a newer PigRider app: \(member)")
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
        }
        .padding()
        .foregroundStyle(.black)
        .background(.yellow, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

struct LoadFailureView: View {
    let message: String
    let retry: @MainActor () -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("The server could not be loaded.").font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Button("Settings", action: openSettings)
                Button("Try again", action: retry).buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
