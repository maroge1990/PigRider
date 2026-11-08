# Server on Unraid (GHCR image), Gate 2

Change: PR #3, the server as an Unraid container from a GHCR image (Mark's
request, 2026-11-09). Kind: small change (ADR 0002), Gate 2. Base `main`.

## Round 1 (open), verdict: needs-attention

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | high | The release script runs with `errexit`/`pipefail`, so a missing `apple/BRIDGE_VERSION` (current `main`, before P1) ends the step before the fallback: the first deploy and pre-P1 rollbacks cannot be released. | **Fixed.** The file is tested with `git cat-file -e` first; absent means 1, any other read failure still fails. Checked under `bash -e -o pipefail` on `main` (absent → 1) and the P1 branch (present → 1), and an app bridge of 0 is refused in both. |
| 2 | medium | One concurrency group per ref: a newer push replaces a queued `main` build, so that commit never gets an image and cannot be released or rolled back to. | **Fixed.** `main` builds use one group per commit (never replaced); PRs keep one group per ref with cancel. Since `main` builds now run in parallel, only the build of `main`'s current head moves `:latest` (`:sha-*` is always pushed; Unraid follows `:release` anyway). |
