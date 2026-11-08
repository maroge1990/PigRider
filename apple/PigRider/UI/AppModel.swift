import Observation
import SwiftUI
import UIKit

/// The app's composition root: settings, the web shell with its bridge, and
/// the chooser state the views show.
@MainActor
@Observable
final class AppModel {
    let settings: ServerSettings
    let chooser = ChooserPresenter()
    let shell: WebShell
    let bridgeVersion: Int
    private(set) var hasServer: Bool
    var isShowingSettings: Bool

    init(store: any KeyValueStoring = UserDefaults.standard) {
        let polyfill: BridgePolyfill
        do {
            polyfill = try BridgePolyfill.bundled()
        } catch {
            preconditionFailure("The app bundle lacks a resource: \(error)")
        }
        settings = ServerSettings(store: store)
        shell = WebShell(polyfill: polyfill, grants: GrantStore(store: store), chooser: chooser,
                         openExternally: { UIApplication.shared.open($0) })
        bridgeVersion = polyfill.version
        hasServer = settings.serverURL != nil
        isShowingSettings = settings.serverURL == nil
        shell.show(server: settings.serverURL)
    }

    /// Saves and loads the server; returns a message for the user if `input` is not accepted.
    func saveServer(_ input: String) -> String? {
        do throws(ServerSettings.Failure) {
            let url = try settings.setServer(input)
            hasServer = true
            isShowingSettings = false
            shell.show(server: url)
            return nil
        } catch {
            switch error {
            case .invalid: return "That is not a server address."
            case .httpNotLocal: return "Plain http:// only works for addresses on your home network, such as 192.168.1.20 or passyflix.local. Use https:// for anything else."
            }
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            UIApplication.shared.isIdleTimerDisabled = true
            shell.sceneDidBecomeActive()
        case .background:
            UIApplication.shared.isIdleTimerDisabled = false
            shell.sceneDidEnterBackground()
        case .inactive:
            // Control Center or a notification: the ride goes on.
            break
        @unknown default:
            break
        }
    }
}
