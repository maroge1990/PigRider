# 1. A native iPad shell around the upstream web client

Date: 2026-11-08 · Status: accepted

## Context

OpenRadlr's client is a web page that needs Web Bluetooth (upstream ADR 0004),
which no iOS browser has. The fork wants the app on an iPad, with an Apple TV
as the big screen, while keeping upstream's ongoing development.
The rider's devices are a KICKR Core, a Zwift Click (two BLE halves) and a Polar
strap, so 3–4 Bluetooth connections at once.

Options considered:

1. **Native rewrite (SwiftUI + Metal).** Most native, but it reimplements the
   renderer, ride logic and device codecs, and drifts from upstream on day one.
2. **Native tvOS app.** tvOS has no WebKit, so this means option 1 as well, and
   Apple TV limits how many Bluetooth accessories can connect at once (Zwift
   documents two besides the remote; unverified here).
3. **Native shell + Web Bluetooth bridge.** A Swift app hosts the client in a
   `WKWebView` and provides `navigator.bluetooth` through CoreBluetooth.

## Decision

Option 3.

- The web view loads the client **from the self-hosted server** (HTTPS), the same
  page a desktop browser gets. A server update ships client updates to the iPad
  without an app release; the app changes only when the bridge does.
- A user script injected at document start defines `navigator.bluetooth` with
  the subset of Web Bluetooth the client uses (see the bridge spec). Upstream's
  `ble/` code, codecs and tests run unchanged.
- The Apple TV is an **AirPlay display** of the iPad: mirroring at first, a
  dedicated full-screen view later (P3).
- The bridge is fork code in `apple/`; it needs no upstream change.

## Consequences

- Upstream device support (new trainers, controllers) works on the iPad for free,
  as long as it stays within the bridged API subset. A new Web Bluetooth call
  upstream fails the contract tests at the weekly merge, and on a device shows
  a native banner. Because the server pushes client updates at once, a server
  deploy must not need a newer bridge than the installed app (see the spec).
- The app depends on the server being reachable; no offline riding.
- Strava sign-in happens inside the web view. Strava's own login works there;
  "Sign in with Google" refuses embedded web views (a known risk, see spec).
- iPadOS suspends web content in the background, so the app keeps the screen
  awake during a ride.
- AGPL: TestFlight/personal installs are fine; an App Store release would need
  its own licence review.
