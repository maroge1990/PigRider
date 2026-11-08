# Upstream files the fork changes

Every file outside `apple/` that differs from `upstream/main`, and why. Keep it
short; check it after each upstream merge (`git diff --stat upstream/main -- . ':!apple'`).

| File | Change | Why |
| --- | --- | --- |
| `AGENTS.md` | "PigRider fork" section at the end | Points agents at `apple/AGENTS.md` |
| `CLAUDE.md` | New, `@AGENTS.md` only | Claude Code loads AGENTS.md |
| `.gitignore` | `CLAUDE.local.md` | Local agent notes stay out of git |
