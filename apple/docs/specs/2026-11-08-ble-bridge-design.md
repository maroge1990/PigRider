# Design: iPad shell and Web Bluetooth bridge (P1)

Date: 2026-11-08 · Status: approved (Codex sign-off 2026-11-08) · ADR: [0001](../adr/0001-native-ipad-shell.md)

## Goal

Ride on an iPad with the upstream client unchanged: a Swift app shows the
self-hosted client in a `WKWebView` and implements the part of Web Bluetooth
the client uses on top of CoreBluetooth. Done when a full ride works with a
KICKR Core (power, cadence, sim grade, ERG, virtual shifting), a Polar strap
and both halves of a Zwift Click, including reconnecting after a dropout,
while mirrored to an Apple TV.

Non-goals: offline riding, background riding (screen off), tvOS, a native UI
for anything the web client already does, the dedicated TV view (P3).

## Layout

```text
apple/
  project.yml              XcodeGen spec (the .xcodeproj is generated, not committed)
  PigRider/                Swift app: App, WebViewController, Settings, Bluetooth/
  PigRiderTests/           XCTest, no hardware: fakes behind the CentralManaging protocol
  web/bluetooth-bridge.js  The navigator.bluetooth polyfill (plain ES, no build step)
  web/test/                node:test for the polyfill, incl. upstream ble/ classes against it
  scripts/mac.sh           rsync apple/ to `ssh mac`, xcodegen, xcodebuild test / archive
  Makefile                 `make -C apple check` = polyfill tests + Mac build and tests
```

The upstream `Makefile` and CI are not touched. `make -C apple check` runs on
top of `make check`.

## The web view

- Loads the server URL entered once in the app's settings (stored in
  `UserDefaults`): `https://` anywhere, or `http://` for a home-network host
  (private address, `.local` name or a name without a dot; see ADR 0001). ATS
  stays on apart from `NSAllowsLocalNetworking`. The default data store
  persists `localStorage` and cookies, so the rider profile, known devices and
  the Strava session survive restarts.
- `isIdleTimerDisabled = true` while the web view is in the foreground.
- Navigation policy: the server's origin and `www.strava.com` (OAuth) load in
  the web view; any other link opens in Safari.
- The polyfill is a `WKUserScript` injected at document start, **main frame
  only**, and it installs itself only when `location.origin` equals the
  configured server origin. Strava's pages never get `navigator.bluetooth`.

## API subset

What upstream's `ble/` uses today (found by grep, 2026-11-08) and the bridge
provides. Anything else throws `NotSupportedError("<method> is not bridged")`,
so a new upstream call fails loudly in the device diagnostics instead of quietly.

| Web Bluetooth | Bridge behaviour |
| --- | --- |
| `navigator.bluetooth.requestDevice({filters, optionalServices})` | Native chooser sheet. Filters: `services`, `name`, `namePrefix`, `manufacturerData[].companyIdentifier`. Cancel → `NotFoundError`. `acceptAllDevices` → `NotSupportedError` (unused). |
| `navigator.bluetooth.getDevices()` | Devices granted earlier (persisted), as `BluetoothDevice` objects, not connected |
| `BluetoothDevice.id`, `.name`, `.gatt` | `id` = `CBPeripheral.identifier` (stable per app) |
| `device.watchAdvertisements({signal})`, `advertisementreceived` | Subscribes this device to the shared scan (see Scanning); fires on each sighting; `signal` abort removes only this subscription |
| `device.forget()` | Drops the grant and disconnects |
| `gattserverdisconnected` | On `didDisconnectPeripheral` (also after `disconnect()`, as in Chrome) |
| `gatt.connect()`, `.disconnect()`, `.connected` | `connect(_:)`; resolves on connect; rejects `NetworkError` on failure |
| `gatt.getPrimaryService(uuid)` | Discovers services; rejects `SecurityError` if the uuid was not in the filters/optionalServices of the grant (Chrome's rule, so behaviour matches desktop), `NotFoundError` if absent |
| `service.getCharacteristic(uuid)` | Discovers characteristics; `NotFoundError` if absent |
| `characteristic.startNotifications()` | `setNotifyValue(true)`; resolves on `didUpdateNotificationStateFor` (notify and indicate alike) |
| `characteristicvaluechanged`, `characteristic.value` | `value` is a fresh `DataView` per event; `event.target` is the characteristic |
| `writeValueWithResponse(bytes)` | `.withResponse`; resolves on `didWriteValueFor` |
| `writeValueWithoutResponse(bytes)` | `.withoutResponse`; waits for `canSendWriteWithoutResponse` / `peripheralIsReady` |

UUIDs: numbers (`0x1826`) and short forms are normalised to lowercase 128-bit
strings in JS, as `BluetoothUUID.getService` does; Swift compares `CBUUID`s.

## Protocol between JS and Swift

- **Calls** (JS → Swift): `window.webkit.messageHandlers.ble.postMessage({op, args})`
  through a `WKScriptMessageHandlerWithReply`, so each call returns a promise.
  Replies are `{ok: true, value}` or `{ok: false, error: {name, message}}`, and
  the polyfill turns errors into `DOMException`s with the same names Chrome uses.
- **Events** (Swift → JS): `callAsyncJavaScript("__pigriderBle.dispatch(e)", arguments: ["e": event])`
  on the main actor, in arrival order. Events: `value` (deviceId, service,
  characteristic, bytes), `disconnected` (deviceId), `advertisement`
  (deviceId, name, rssi).
- Bytes cross as base64 strings. Rates are low (trainer ≤ 4 Hz, HR 1 Hz,
  controller on press), so JSON is fine.
- Every call carries a device id; Swift rejects ids not granted **to the
  calling origin** and services outside that grant. Payloads are length-checked
  (≤ 512 bytes).
- Every event carries the connection's epoch (incremented on each connect);
  the polyfill drops events from an older epoch.
- Messages are accepted only from the main frame whose security origin is the
  configured server origin.

## Swift side

- `BluetoothBridge` (main actor) owns one `CBCentralManager` through a
  `CentralManaging` protocol, so tests drive it with a fake central and fake
  peripherals.
- Per peripheral, one FIFO of pending operations per characteristic (CoreBluetooth
  callbacks carry no request id). A disconnect rejects everything pending with
  `NetworkError` and clears the GATT cache.
- `GrantStore`: (canonical origin, device id) → {name, allowed service UUIDs},
  in `UserDefaults`. Every native operation checks the grant of the calling
  origin, not just that some grant exists. Changing the server URL in settings
  disconnects every peripheral, rejects pending operations and reloads; grants
  of the old origin stay with that origin.
- **Scanning:** one `ScanCoordinator` owns the scan. Consumers are the chooser
  and each `watchAdvertisements` subscription; each gets the sightings that
  match it. Aborting removes only that consumer; the scan stops when none is
  left. (upstream `main.js` watches the trainer, strap and both Click halves at
  once, and each watch aborts on its first sighting.)
- Chooser: a SwiftUI sheet listing peripherals that match the filters, updated
  live from a scan. Scans run with `nil` services and filter in the app, because
  a Zwift Click advertises manufacturer data (company 0x094A), not its service.
- Bluetooth off or not authorised → `requestDevice` rejects `NotFoundError`
  with a message that says so; `Info.plist` has `NSBluetoothAlwaysUsageDescription`.
- **Background and suspension.** No `bluetooth-central` background mode in v1.
  iOS does not reliably drop connections of a suspended app (it queues their
  events for the return), and upstream reconnects only on
  `gattserverdisconnected`. So the bridge decides instead of the OS:
  - On `didEnterBackground` (not `willResignActive`, so Control Center or a
    notification does not end the ride) the bridge cancels every connection,
    rejects pending operations with `NetworkError`, pauses the scan and bumps
    every epoch, so queued values are dropped. Scan consumers (watches, an
    open chooser) are kept; an abort while suspended still removes its consumer.
  - On return to the foreground it resumes the scan if consumers remain (a
    remembered Click waiting for a button press keeps waiting) and dispatches
    `gattserverdisconnected` for each device that was connected; upstream's `Reconnector` then reconnects and
    sends request-control, start and the current grade or target power again.
  - Until then the trainer may hold its last grade or ERG target, the same as
    when a desktop browser tab loses Bluetooth; the hardware checklist covers it.
  - Tests: background with a connection that survives, and with one that
    dropped while suspended; both end in one clean reconnect and no stale
    readings. Background while several remembered devices await
    advertisements, with one watch aborted during suspension: the others get
    their sightings after the return.
- **Document lifetime.** Native Bluetooth state belongs to one document.
  The bridge keeps a document generation, bumped when a main-frame navigation
  commits (including a reload and the Strava OAuth round trip) and on
  `webViewWebContentProcessDidTerminate`. A bump cancels every connection,
  removes all scan consumers, closes the chooser, rejects pending calls and
  discards their late replies and events. Each call records the generation it
  arrived in; work from an older generation is dropped. Grants stay (they
  belong to the origin, as `getDevices()` does in Chrome). Tests: reload,
  OAuth navigation and content-process termination, each with a connection,
  a pending write, a watch and an open chooser.

## Testing

- **Polyfill (node:test, no browser)**: a fake native channel records calls and
  injects events. Contract tests run upstream's own `SmartTrainer`,
  `HeartRateMonitor` and `ZwiftController` (imported from `client/public/js/ble/`)
  against the polyfill with byte fixtures, so an upstream change that steps
  outside the bridged subset fails these tests at the next merge.
- **Swift (XCTest on the Mac)**: filter matching, UUID handling, grant checks,
  operation queues, disconnect handling, origin checks; all with the fake central.
- **Hardware checklist** (manual, recorded in the PR): KICKR Core power/cadence,
  grade changes felt, ERG holds target, virtual shift steps; Polar HR; Click
  both halves (and the known lock-up of the left half after ~1 min); trainer
  power-cycled mid-ride reconnects; app background/foreground; AirPlay mirroring
  to the Apple TV for a 30 min ride.

## Risks

- **Strava sign-in in a web view:** Strava email/password works; "Sign in with
  Google" rejects embedded web views. If that blocks Mark, the fallback is
  `ASWebAuthenticationSession` plus a one-time code exchange on the server,
  which would be an upstream change.
- **WebGL performance on iPad while mirroring** is unmeasured; measure in P1
  before P3 commits to a 3D TV view.
- **Upstream starts using an unbridged API** (e.g. `getAvailability`): caught by
  the contract tests at the weekly merge. On a device it must not fail quietly
  (upstream catches some errors and degrades, e.g. a trainer to power-only), so
  every `NotSupportedError` is also reported to Swift, which shows a native
  banner ("This server needs a newer PigRider app: <method>").

## Bridge versions and server deploys

The server pushes client updates to installed apps immediately, so the client
on passyflix must never need more than the installed app's bridge provides.

- `apple/BRIDGE_VERSION` (an integer) is bumped whenever the bridged subset
  grows. The polyfill exposes it as `navigator.bluetooth.pigriderBridge = {version, ops}`.
- The contract tests record the Web Bluetooth calls upstream's `ble/` makes; a
  merge that needs a new op fails them until the bridge (and the version) grows.
- **Deploy rule:** passyflix only gets a fork commit whose `BRIDGE_VERSION` is
  ≤ the version of the build installed on the iPad (from TestFlight). The
  weekly merge routine (P4) checks this before deploying; if a merge needs a
  newer bridge, the app ships to TestFlight first, then the server.
- Single rider, single server: that policy is enough. No in-page negotiation
  is needed, since the banner above catches a mistake visibly.
- **CoreBluetooth vs Chrome timing differences** (first-connect retries,
  service discovery caching) may expose assumptions in upstream code; the
  diagnostics panel logs raw packets for comparison with desktop Chrome.
