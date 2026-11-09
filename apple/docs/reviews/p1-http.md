# P1 follow-up: plain HTTP at home, Gate 2

Change: the app accepts `http://` server URLs for home-network hosts (Mark's
choice, 2026-11-09; ADR 0001). Kind: small change (ADR 0002): failing tests
first, then Gate 2. Base `9a7cfcc`, change `ec491da`.

## Round 1 (open), verdict: needs-attention

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | medium | Accepted hosts are saved as typed, but WebKit serialises some differently (`[fd12:3456:0:0:0:0:0:1]` → `[fd12:3456::1]`, `192.168.1.20.` → `192.168.1.20`), so the saved origin differs from `location.origin`: the polyfill does not install and native rejects the messages. | **Fixed.** `ServerHost.canonical` puts every host (any scheme) in the URL Standard's form: IPv6 compressed and lowercase, an IPv4 trailing dot dropped. Hosts it does not mirror are refused: IPv4 shorthand, IPv6 zones or embedded IPv4, and non-ASCII or percent-encoded names. Tests: `hostsAreSavedAsTheBrowserWritesThem`, `hostsWebKitWouldRewriteAreRefused`, and the WKWebView round trip `aTypedServerAddressGetsAWorkingBridge` (typed address → `normalise` → real page: `location.origin` equals the saved origin, the bridge installs, a call succeeds). |

Checks after the fix: `make -C apple check` (132 bridge tests, 197 Swift tests),
`make check` (upstream lint and tests).

## Round 2 (fixes only), verdict: approve

Fix `832f35f` checked against round 1: the finding is resolved, no in-scope
regression. No findings.

## Sign-off, verdict: approve

Codex: finding 1 fixed (yes), no rejections or deferrals, no regression found;
ADR 0001 states the accepted HTTP risks honestly. Gate passed.
