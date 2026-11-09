# Roadmap

| Phase | Goal | Done when |
| --- | --- | --- |
| P0 | Fork setup, ADRs, Bluetooth bridge design | Design passed the Codex design review |
| P1 | iPad shell + CoreBluetooth bridge | A full ride on the iPad with the KICKR Core, Polar and Click; JS and Swift tests green |
| P2 | Server on passyflix; intervals.icu upload from the finish screen (Strava left off, 2026-11-09) | One ride appears on intervals.icu from the finish screen |
| P3 | TV view: 3D world full screen on the AirPlay display, stats on the iPad | Rode a session with the TV as display |
| P4 | TestFlight build and weekly upstream merge routine | Installed from TestFlight; one upstream merge done by the routine |

Strava upload is built (upstream code, Unraid fields in place) but left off:
since June 2026 Strava's API needs the developer's account to be a paid Strava
subscriber, and Mark isn't one. Rides go to intervals.icu; Strava by hand
(download the FIT on intervals.icu, upload at strava.com/upload). To switch it
on later: subscribe, then step 1 in [server.md](server.md).

Out of scope for now: a native tvOS app (no WebKit on tvOS, too few Bluetooth
slots; see ADR 0001), App Store release (AGPL).
