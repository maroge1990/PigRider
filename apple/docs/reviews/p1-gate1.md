# P1 Gate 1 (design) review log

## Round 1, 2026-11-08: needs-attention

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | high | No recovery rule after a GATT op timeout; a late callback could complete the next op | Fixed: property checks first; timeout cancels the connection, rejects all pending, fences callbacks by connection state (protocol "GATT operations and timeouts"); T6 test of the A-times-out/B/late-A sequence |
| 2 | high | Order of connect replies vs disconnect events undefined; a late reply could overwrite a disconnect | Fixed: epochs assigned at connect start, "disconnect wins" and superseded-attempt rules (protocol "Connection state and timing"); T2 tests for both orders; T7 WKWebView round-trip test |

## Round 2 (fixes only), 2026-11-08: needs-attention

Finding 1's fix was not disputed. Finding 2's fix introduced a race:

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 3 | high | Cleanup of a superseded connect sent an unconditional disconnect that could cut a newer connection | Fixed: `disconnect` takes an optional `epoch` and is ignored if stale; one link per device shared by attempts; T2/T6 tests where B connects before A's late success and stays connected |

## Sign-off 1, 2026-11-08: needs-attention

Findings 2 and 3: resolved, no regression. Finding 1: not resolved. The
timeout teardown exposes an upstream race: optional set-up errors are
swallowed and `#open` sets `connected = true` even if the link dropped, with
the disconnect listener added only afterwards.

Fix: plan task T3b, an upstream fix (`#open` fails with `NetworkError` when
`gatt.connected` is false at its end) plus T3 contract cases for timeouts
during trainer take-control and OBC app info, on first connect and reconnect.

## Sign-off 2, 2026-11-08: approve

Finding 1 resolved at design level with T3b; no regression. Gate 1 passed.
Implementation is checked at Gate 2.
