# P1 follow-up: copy to the clipboard over plain HTTP, Gate 2

Change: over plain HTTP WebKit gives the page no `navigator.clipboard`, so the
client's Copy report failed on the iPad (found during the hardware checklist,
2026-11-09). The polyfill provides `clipboard.writeText` there and the bridge's
new `copyText` op puts the text on the clipboard after the rider confirms it.
Kind: small change (ADR 0002): failing tests first, then Gate 2. Base
`ef7b9e5`, change `d4d25c9`; Mark chose a native Copy / Cancel prompt.

## Round 1 (open), verdict: needs-attention

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | high | The page could post `copyText` to the `ble` handler directly and skip the polyfill's `userActivation` check, so the app wrote the clipboard without a tap. | **Fixed** in `ebb5bf7`. The app asks the rider (native Copy / Cancel prompt with the text's first line) and copies only on Copy; Cancel rejects with `NotAllowedError`; one prompt at a time. Test: `aCopyPostedStraightToTheAppStillNeedsTheRidersOK` (real WebKit page posting directly). |

## Round 2 (fixes only), verdict: needs-attention

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 2 | medium | A prompt dismissed without a button (a reload dismissing the device chooser it was shown on) left the bridge's prompt flag set, so every later copy was refused. | **Fixed** in `9638c31`. `CopyPrompting.cancel()` on document change; prompts are numbered and a late answer is ignored; `CopyPrompt` answers exactly once (a button, `cancel()`, vanishing with the view it sat on, or UIKit refusing to show it). Tests: `ClipboardTests` reload cases, `CopyPromptTests` (real alert in a window). |

## Round 3 (fixes only), verdict: approve

No findings.

## Sign-off, verdict: approve

Both findings fixed, no regression.

Checks: 139 JS bridge tests, 216 Swift tests on the iPad simulator. Not
covered: tapping the alert's real buttons (UIKit has no API for it); the
TestFlight build is the first check that Copy copies.
