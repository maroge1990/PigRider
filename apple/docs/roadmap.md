# Roadmap

| Phase | Goal | Done when |
| --- | --- | --- |
| P0 | Fork setup, ADRs, Bluetooth bridge design | Design passed the Codex design review |
| P1 | iPad shell + CoreBluetooth bridge | A full ride on the iPad with the KICKR Core, Polar and Click; JS and Swift tests green |
| P2 | Server on passyflix; intervals.icu upload (upstream PR); upload to both on finish | One ride appears on Strava and intervals.icu without manual steps |
| P3 | TV view: 3D world full screen on the AirPlay display, stats on the iPad | Rode a session with the TV as display |
| P4 | TestFlight build and weekly upstream merge routine (TestFlight moved ahead of P1's ride test, 2026-11-09) | Installed from TestFlight; one upstream merge done by the routine |

Out of scope for now: a native tvOS app (no WebKit on tvOS, too few Bluetooth
slots; see ADR 0001), App Store release (AGPL).

## Backlog

- Ride file downloads (`.tcx`, `.fit`, `.gpx`) in the iPad app: the web view
  needs a `WKDownloadDelegate` and a share sheet. Uploads to Strava and
  intervals.icu don't need it. (P1 T7)
- Links that open a new window (`target=_blank`, `window.open`) go to Safari,
  so the ride page is never replaced. Revisit if a server page needs a popup.
- Lint `apple/web/` (ESLint as in `client/`) in `make -C apple check` and CI; today nothing lints it. (P1 Gate 2)
