# Upstream files the fork changes

Every file outside `apple/` that differs from `upstream/main`, and why. Keep it
short; check it after each upstream merge (`git diff --stat upstream/main -- . ':!apple'`).

| File | Change | Why |
| --- | --- | --- |
| `AGENTS.md` | "PigRider fork" section at the end | Points agents at `apple/AGENTS.md` |
| `CLAUDE.md` | New, `@AGENTS.md` only | Claude Code loads AGENTS.md |
| `.gitignore` | `CLAUDE.local.md` | Local agent notes stay out of git |
| `.github/workflows/pigrider-image.yml` | New | Builds and smoke-tests the server image, pushes it to GHCR (`docs/server.md`) |
| `.github/workflows/pigrider-release.yml` | New | Moves `:release` for Unraid, enforcing the bridge deploy rule |
| `server/crates/server/src/intervals.rs`, `config.rs`, `http.rs`, `app.rs`, `lib.rs`, `tests/intervals_upload.rs`; `client/public/js/net/intervals.js`, `main.js`, `index.html`, `i18n/{en,de}.js`, `client/test/intervals.test.js`; `docs/protocol.md`, `docs/deploy.md`, `README.md`, `.env.example`, `docker-compose.yml`, `CHANGELOG.md`, the design spec | intervals.icu upload with the server's key (PR #5) | P2; drop these rows if upstream takes it |
