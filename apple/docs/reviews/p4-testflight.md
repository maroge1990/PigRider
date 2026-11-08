# TestFlight tooling, Gate 2

Change: `make -C apple testflight` / `ipad` (Mark's request, 2026-11-09:
TestFlight before the P1 ride test). Kind: small change (ADR 0002), Gate 2.
Base `fork/p1-ble-bridge`, change `225e0cd`.

## Round 1 (open), verdict: needs-attention

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | high | All commands sync into one folder on the Mac: while an upload waits for the password or archives, another run can replace its sources, so the upload carries code that matches no commit; parallel uploads also share the archive paths. | **Fixed.** A TestFlight run extracts `git archive HEAD:apple` into its own folder (`build/PigRider-release/<build>-<commit>`) and archives and exports there; the folder is removed after a successful upload. The shared folder is used only by test, simulator and development builds. |
| 2 | medium | Build number = commit count collides between branches and can run ahead of `main`, blocking later uploads. | **Fixed.** Build number = Unix time of the run (only grows, any branch, retries included). The commit goes into the bundle (`PigRiderCommit`) and the settings screen shows `version (build, commit)`; tests cover both. |
