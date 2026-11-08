# Upstream files the fork changes

Every file outside `apple/` that differs from `upstream/main`, and why. Keep it
short; check it after each upstream merge (`git diff --stat upstream/main -- . ':!apple'`).

| File | Change | Why |
| --- | --- | --- |
| `AGENTS.md` | "PigRider fork" section at the end | Points agents at `apple/AGENTS.md` |
| `CLAUDE.md` | New, `@AGENTS.md` only | Claude Code loads AGENTS.md |
| `.gitignore` | `CLAUDE.local.md`; `apple/*.xcodeproj/`, `apple/build/` | Local agent notes and generated Xcode files stay out of git |
| `.github/workflows/apple.yml` | New | CI for the bridge polyfill tests (the Swift build runs on the Mac) |
| `.github/workflows/pigrider-image.yml` | New | Builds and smoke-tests the server image, pushes it to GHCR (`docs/server.md`) |
| `.github/workflows/pigrider-release.yml` | New | Moves `:release` for Unraid, enforcing the bridge deploy rule |
| `client/public/js/ble/{devices,zwiftController,openBikeControl}.js`, `client/test/{fakeBluetooth.js,linkLostDuringOpen.test.js}` | `#open` fails with `NetworkError` when the link dropped during set-up (commit ace5072) | Bug fix (P1 T3b); to be PR'd upstream, drop from here once merged |
