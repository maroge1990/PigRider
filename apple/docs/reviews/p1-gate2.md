# P1 Gate 2 (code) review log

## Round 1, 2026-11-08: needs-attention

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | high | `BluetoothBridge.connect` starts a new attempt while a cancelled one is still draining; a late `didConnect` is taken as the new attempt's | Fixed (09794c5): `draining` link state; connects queue until didDisconnect/didFailToConnect or 6 s; late didConnect and GATT callbacks ignored; 10 new/changed tests incl. the finding's exact sequence and a document reload |
| 2 | medium | Polyfill keeps service/characteristic objects across connections; closed upstream adapters keep receiving notifications | Fixed (24902b7): discovery per connection; stale objects reject `InvalidStateError` (after reconnect) / `NetworkError` (disconnected), as in Chrome; 10 new tests incl. upstream HeartRateMonitor and SmartTrainer reopen |

Note: Codex's sandbox could not run `make check` (no network for crates.io) or the
Swift tests. Both are run on the orchestrator's side for each round.

## Round 2 (fixes only), 2026-11-08: approve

Both fixes resolve their findings; no new high-severity issue.

## Deferred (for sign-off)

| Item | Why deferred | Where tracked |
| --- | --- | --- |
| A cancel answered only after the 6 s drain fallback fails the next attempt once (page retries; sessions never mix) | Depends on real CoreBluetooth timing; only hardware shows it | `apple/docs/hardware-checklist.md`, last item |
| `apple/web/` is not linted | Tooling gap that existed before this change, no behaviour impact | `apple/docs/roadmap.md` backlog |
| Ride file downloads in the web view | Not needed for P1; uploads are server-side | `apple/docs/roadmap.md` backlog |

## Sign-off 1, 2026-11-08: needs-attention

- Finding 2: fixed, no regression (bluetooth-bridge.js 194–224; tests in
  polyfill.test.js and upstreamContract.test.js).
- Deferrals: lint and downloads accepted.
- Finding 1 / first deferral **contested**: the 6 s drain timeout ends the
  quarantine without a cancel acknowledgement, so a late `didConnect` and
  GATT callbacks of the cancelled link can still be taken as the next
  attempt's. Not limited to one failed attempt.

Fix (in progress): the timer alone never ends the drain. At the timeout,
CoreBluetooth's `peripheral.state` decides: `.disconnected` ends it; anything
else cancels again, rejects queued attempts with `NetworkError` (the page
retries) and keeps draining until a terminal callback or a later check finds
`.disconnected`.

Fixed (9653195): `PeripheralHandle.state`; at the timeout only
`.disconnected` ends the drain; otherwise cancel again, reject queued
connects with `NetworkError`, keep draining, and reject later connects until
CoreBluetooth answers or reports `.disconnected`. Tests: Codex's sequence for
`.connecting`, `.connected` and `.disconnecting`; the `.disconnected`
variant; connects after an expired drain; the document-reload variant; the
state mapping. 187 Swift tests pass.

Deferral replaced: the old first row is withdrawn. New deferred item:

| Item | Why deferred | Where tracked |
| --- | --- | --- |
| State reads `.disconnected` at the timeout but the old `didDisconnect` is still queued: that callback fails the new attempt once with `NetworkError` (the page retries; no session exists to mix) | Whether CoreBluetooth ever reports this state ahead of its callback is only observable on hardware | `apple/docs/hardware-checklist.md`, last item |

## Sign-off 2, 2026-11-08: approve

Finding 1 resolved (BluetoothBridge.swift 251–257, 347–359; tests in
BridgeConnectionTests 225–300 and BridgeLifecycleTests 184–202). The
queued-didDisconnect deferral is accepted: callbacks run on the main queue, so
the old terminal callback rejects the pending attempt before its didConnect,
leaving no session to mix. Gate 2 passed; hardware timing stays on the
checklist.
