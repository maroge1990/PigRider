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
