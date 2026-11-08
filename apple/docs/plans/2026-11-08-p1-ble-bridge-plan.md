# Plan: P1, iPad shell and Bluetooth bridge

Spec: [ble-bridge design](../specs/2026-11-08-ble-bridge-design.md) (approved).
Message format: [bridge-protocol.md](../bridge-protocol.md).

Every task is test-first. `make -C apple check` must pass after each task.

## Tooling decisions

- **XcodeGen** (`apple/project.yml`) generates the project on the Mac; the
  `.xcodeproj` is gitignored, so there are no `project.pbxproj` merge conflicts.
- iPadOS 18+ deployment target, iPad only, landscape. Swift 6 language mode;
  the bridge is `@MainActor` and CoreBluetooth runs on the main queue.
- **Swift Testing** for unit tests, on the iPad Pro 11" (M5) simulator.
  The simulator has no Bluetooth, so every CoreBluetooth type sits behind a
  protocol (`CentralManaging`, `PeripheralHandle`) with fakes.
- `apple/scripts/mac.sh` rsyncs `apple/` to `mac:~/build/PigRider/apple`, runs
  `xcodegen` and `xcodebuild test` (or `archive`). Logs are kept in
  `~/.cache/pigrider/` locally; only the summary is printed.
- The polyfill is one classic script (no modules, it is a `WKUserScript`).
  It defines `installPigriderBluetooth(target, {origin, channel})` and, in the
  app, runs it once against `globalThis` when `location.origin === origin`.
  Node tests load it with `vm` into a context with fakes.
- `apple/Makefile`: `check` = `node --test apple/web/test/` + `scripts/mac.sh test`.
  Upstream's `Makefile` and CI stay untouched. Fork CI for `apple/web` tests
  is added to `.github/workflows/apple.yml` (Linux, node 22); the Swift build
  stays on the Mac until P4.

## Tasks

**T1. Scaffolding.** `project.yml`, app target with a blank SwiftUI view,
test target with one passing test, `BRIDGE_VERSION` (= 1), `Makefile`,
`scripts/mac.sh`, `.gitignore` for generated files, `apple.yml` workflow.
Done: `make -C apple check` green.

**T2. Polyfill (JS).** Tests with a fake channel for: UUID normalisation
(numbers, short hex, full, invalid → `TypeError`); `requestDevice` and
`getDevices` returning the same `BluetoothDevice` object per id; errors
mapped to `DOMException` names; `gatt.connected` kept in sync with
`connect`, `disconnect()` and `disconnected` events; `gattserverdisconnected`
after `disconnect()`; `characteristicvaluechanged` with a fresh `DataView`
and `event.target` = characteristic; stale-epoch events dropped;
`watchAdvertisements` with a `signal` (abort → `unwatchAdvertisements`,
already-aborted signal → `AbortError`); writes accept ArrayBuffer, typed
arrays and DataView; any other API member throws `NotSupportedError` and
sends `reportUnsupported`; `pigriderBridge = {version, ops}`; no install
when the origin does not match. Timing (protocol "Connection state and
timing"): `disconnected` for epoch E before the connect reply for E → connect
rejects `NetworkError`, `connected` stays false; reply before event → resolves,
then `gattserverdisconnected`; `disconnect()` during connect → late success
reply triggers a `disconnect` call and `AbortError`; a newer `connect()`
supersedes an older reply; attempt A succeeds late after attempt B
connected → B stays connected (cleanup, if any, carries A's epoch).

**T3. Contract tests (JS).** A fake native side (in JS) that implements
`bridge-protocol.md` over scripted peripherals: a KICKR-like FTMS + Cycling
Power trainer, an HR strap, a Zwift Click half, an OpenBikeControl remote.
Upstream's own `SmartTrainer`, `HeartRateMonitor`, `ZwiftController` and
`connectController` (imported from `client/public/js/ble/`) and
`whenInRange`/`grantedDevices` run against the polyfill: data flows, grade and
ERG writes arrive as the right bytes, Click buttons decode, a disconnect
triggers upstream's reconnect. A recorder lists every Web Bluetooth member
upstream touched, and the test fails on one outside the bridged set.

**T3b. Upstream fix: fail an open when the link dropped during it.** Upstream's
device classes swallow errors from optional set-up steps (`SmartTrainer`'s
take-control, `OpenBikeControlController`'s app info) and then set
`connected = true`; their `gattserverdisconnected` listener is added only after
the first open. A link lost mid-open (on Chrome too, and more likely with the
bridge's timeout rule) leaves a dead device that looks connected and never
reconnects. Fix in `devices.js` (trainer, HR monitor), `zwiftController.js` and
`openBikeControl.js`: the last step of each `#open` throws `NetworkError` if
`device.gatt.connected` is false. No `await` follows that check before the
listener is added, and bridge events arrive as tasks, so nothing can slip in
between. Test-first in `client/test/` (fake device whose link drops during
take-control / app info: open rejects; under `Reconnector`, no false
`onBack`, another attempt follows). Branch from `upstream/main`, Gate 2,
then PR to Lethonium/OpenRadlr with Mark's OK; carried in the fork (listed in
`upstream-delta.md`) until merged. T3 adds contract cases: a timeout during
trainer take-control and during OBC app info, on first connect and on
reconnect, with `disconnected` delivered before the operation's rejection;
the device ends disconnected and reconnecting, never "connected".

**T4. Swift, pure parts.** `BluetoothUUID` normalisation; `RequestFilter`
matching against an advertisement (services, name, prefix, manufacturer
company id); `BridgeCall` decoding and limits (from `protocol.json`);
`GrantStore` keyed by (origin, id) over a `KeyValueStoring` fake;
`ServerSettings` (HTTPS only, canonical origin); `NavigationPolicy` (server
origin and `www.strava.com` in the web view, everything else in Safari).

**T5. Swift, scanning.** `ScanCoordinator` with consumers (chooser, watches):
one scan for many; abort removes one; the scan stops at zero; pause on
background keeps consumers; resume on foreground; a generation bump removes
all consumers.

**T6. Swift, bridge.** `BluetoothBridge` against `FakeCentral`: every op in
the protocol; grant checks per origin; per-characteristic FIFO of pending
operations; property checks before any CoreBluetooth call (`NotSupportedError`);
10 s native timeout per GATT op that cancels the connection, rejects everything
pending and emits `disconnected`; the sequence "write A times out, write B is
requested, A's callback arrives late" never resolves B with A's callback;
epochs assigned at connect start; a disconnect during connect; `disconnect`
with a stale epoch is ignored while one without an epoch always cancels; a
second `connect` while one is pending shares the link; service and
characteristic discovery cached per connection; epochs; disconnect rejects
pending work and emits `disconnected`; background disconnects everything,
bumps epochs, foreground emits `disconnected` for previously connected
devices; document generation bump cancels connections, consumers, chooser
and pending calls and discards late replies; server change does the same.
Events go out through an `EventSink` protocol (fake in tests).

**T7. App integration.** `WebView` (`WKWebView` with the user script and the
reply handler in the `.page` world, origin + main-frame check on every
message, `EventSink` over `callAsyncJavaScript`, generation bump on
`didCommit` and `webViewWebContentProcessDidTerminate`, navigation policy);
SwiftUI chooser sheet; settings screen (shown when no server is set, or by a
three-finger long press); unsupported-API banner; idle timer off while
active; scene-phase hooks into the bridge; `NSBluetoothAlwaysUsageDescription`.
Done: simulator screenshot of the client loaded from the server, and
`navigator.bluetooth.pigriderBridge.version === 1` in the page. Plus a
round-trip test in the simulator: a real `WKWebView` loads a test page
(`loadHTMLString` with the configured origin as base URL) wired to the real
polyfill, message handler and event sink over `FakeCentral`; it covers
request → connect → notify → write, and a disconnect delivered before the
connect reply (`gatt.connected` ends false). A page from another origin gets
no `navigator.bluetooth` and its messages are rejected.

**T8. Hardware checklist** in `apple/docs/hardware-checklist.md` (from the
spec), run by Mark on the iPad with a development build. Results go in the PR.

## Order and delegation

T1 first (me). T3b is small and goes with the JS builder. Then T2+T3+T3b (JS) and T4–T6 (Swift) run in parallel, each by a
builder in its own worktree; `bridge-protocol.md` and `protocol.json` (written
in T1) are the fixed contract between them. T7 and T8 after both, by me.
Gate 2 runs on the whole branch.

## Open items

- Xcode on the Mac knows only the free Personal Team; installing on the iPad
  needs the paid team signed in (Mark), before T8.
- T7 and T8 need the client served over HTTPS. The Mac has no Rust or node,
  so the basic server deployment on passyflix (Docker Compose behind its
  existing proxy, no Strava yet) moves forward from P2 to before T7, with
  Mark's OK. Its hostname and certificate are Mark's to choose.
