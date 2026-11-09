# P1 follow-up: iPadOS 17 and later, Gate 2

Change: the deployment target drops from iPadOS 18 to 17 (Mark's call,
2026-11-09). Kind: small change (ADR 0002): Gate 2 only. Base `7e0c133`,
change `469c138`.

Checked before the review: the app builds for iOS 17 with no availability
errors; `apple/web/bluetooth-bridge.js` and `client/public` (JS, CSS, module
worker, WebGL2) use nothing Safari 17 lacks (popover is 17.0;
`backdrop-filter` and `user-select` keep their `-webkit-` forms). New test
`PlatformTests` pins `MinimumOSVersion` to 17.0.

## Round 1 (open), verdict: approve

No findings. Codex notes the approval rests on static review: the Mac only has
iOS 27 simulators, so nothing has run on iPadOS 17 yet. Next step it suggests:
the hardware checklist on an iPadOS 17 iPad, noting the exact OS version.

No round 2 or sign-off needed: there were no findings to fix.

Checks: `scripts/mac.sh test` (199 Swift tests on the iPad simulator).
