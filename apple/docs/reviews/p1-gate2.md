# P1 Gate 2 (code) review log

## Round 1, 2026-11-08: needs-attention

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | high | `BluetoothBridge.connect` starts a new attempt while a cancelled one is still draining; a late `didConnect` is taken as the new attempt's | Fixed (09794c5): `draining` link state; connects queue until didDisconnect/didFailToConnect or 6 s; late didConnect and GATT callbacks ignored; 10 new/changed tests incl. the finding's exact sequence and a document reload |
| 2 | medium | Polyfill keeps service/characteristic objects across connections; closed upstream adapters keep receiving notifications | Fixed (24902b7): discovery per connection; stale objects reject `InvalidStateError` (after reconnect) / `NetworkError` (disconnected), as in Chrome; 10 new tests incl. upstream HeartRateMonitor and SmartTrainer reopen |

Note: Codex's sandbox could not run `make check` (no network for crates.io) or the
Swift tests. Both are run on the orchestrator's side for each round.
