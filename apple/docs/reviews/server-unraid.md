# Server on Unraid (GHCR image), Gate 2

Change: PR #3, the server as an Unraid container from a GHCR image (Mark's
request, 2026-11-09). Kind: small change (ADR 0002), Gate 2. Base `main`.

## Round 1 (open), verdict: needs-attention

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | high | The release script runs with `errexit`/`pipefail`, so a missing `apple/BRIDGE_VERSION` (current `main`, before P1) ends the step before the fallback: the first deploy and pre-P1 rollbacks cannot be released. | **Fixed.** The file is tested with `git cat-file -e` first; absent means 1, any other read failure still fails. Checked under `bash -e -o pipefail` on `main` (absent → 1) and the P1 branch (present → 1), and an app bridge of 0 is refused in both. |
| 2 | medium | One concurrency group per ref: a newer push replaces a queued `main` build, so that commit never gets an image and cannot be released or rolled back to. | **Fixed.** `main` builds use one group per commit (never replaced); PRs keep one group per ref with cancel. `:sha-*` is always pushed. (The round-1 fix also guarded `:latest`; see round 2.) |

## Round 2 (fixes only), verdict: needs-attention

Findings 1 and 2: resolved.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 3 | high | With parallel `main` builds, the head check and the `:latest` push are not serialised: an older run can pass the check, stall, and overwrite a newer `:latest`. | **Fixed by removal.** Nothing uses `:latest` (Unraid follows `:release`; a release promotes `:sha-<commit>`), so the workflow no longer publishes it. No shared mutable tag is left in the build; `:release` moves only in `pigrider-release.yml`, whose concurrency group serialises runs. |
