# AGENTS.md: PigRider (iPad fork)

PigRider is a fork of [Lethonium/OpenRadlr](https://github.com/Lethonium/OpenRadlr):
an iPad app that runs the upstream web client in a native shell and connects
to a self-hosted server. The Apple TV is an AirPlay display. Upstream's AGENTS.md
and CONTRIBUTING.md still apply. This file covers only what the fork adds.

Rider setup: Wahoo KICKR Core, Zwift Click + Cog, Polar HR strap; rides go to
Strava and intervals.icu.

## Keeping close to upstream
- `main` is the fork's integration branch: upstream merged in weekly
  (`git fetch upstream && git merge upstream/main`) plus the fork's PRs.
- Fork code lives in `apple/`. Touch upstream files only through a small seam,
  and list every such file in `apple/docs/upstream-delta.md`.
- Anything generic (e.g. intervals.icu upload) goes upstream: branch from
  `upstream/main`, PR to `Lethonium/OpenRadlr`, carry it here until merged.
- Fork ADRs, specs and plans go in `apple/docs/{adr,specs,plans}`, numbered
  separately from upstream's `docs/adr` so the two never collide.

## Building
- The Mac is reachable as `ssh mac` (Apple Silicon, Xcode 27, iOS 27 simulators,
  paid developer account). It has no node or cargo; JS and Rust run here.
- iOS builds and tests run on the Mac with `xcodebuild` (script added in P1).
- The server runs on `passyflix` as an Unraid container (`PigRider`, image from GHCR),
  over plain HTTP on the home network only (ADR 0001): [docs/server.md](docs/server.md).

## Review process (every change)
The full process is [ADR 0002](docs/adr/0002-fork-maintenance-and-review-gate.md). In short:
- Features: spec → **Gate 1** (Codex on the design) → test-first build →
  **Gate 2** (Codex on the branch diff) → PR → merge on Mark's OK.
- Each gate: round 1 open; round 2 checks the fixes only; then a Codex
  **sign-off** of every finding (fixed / rejection accepted / no regression).
  Only an `approve` sign-off passes. Contested twice → Mark decides.
- Bug fixes: Gate 2 only. Clean upstream merges: checks only.
- Keep the findings log in the PR description.

Run reviews from WSL (Codex is installed and logged in there):
`node ~/.claude/plugins/cache/openai-codex/codex/<ver>/scripts/codex-companion.mjs adversarial-review --base main [focus]`

## Roadmap
`apple/docs/roadmap.md`. GitHub issues are disabled on the fork for now.
