# 2. Fork maintenance and the review process

Date: 2026-11-08 · Status: accepted

## Context

The fork must keep taking upstream changes (several merges a week), and Mark
wants every change to pass two adversarial Codex reviews. Adversarial reviews
almost always find something, so a rule like "re-run until clean" never ends.
Fixes made after the last review must not merge unseen either.

## Decision

### Branches
- `main` is the integration branch: a weekly `git merge upstream/main` plus fork
  PRs. Fork code lives in `apple/`; upstream files change only through small
  seams listed in `apple/docs/upstream-delta.md`.
- Fork work branches from `main` (`fork/<name>`). Generic features branch from
  `upstream/main`, are PR'd to Lethonium/OpenRadlr and carried here until
  merged, then dropped from the delta.

### The process
1. **Intake:** scope agreed with Mark (one question at a time), roadmap entry.
2. **Spec and plan** (features) in `apple/docs/{specs,plans}`.
3. **Gate 1, design:** Codex adversarial review of the spec and plan, before code.
4. **Build, test-first.** Green means `make check`, `make -C apple check` and,
   when Bluetooth or ride code changed, the hardware checklist on the bike.
5. **Gate 2, code:** Codex adversarial review of the branch against `main`.
6. **PR** with the review log, docs and `upstream-delta.md` updated.
7. **Merge** on Mark's approval; deploy to passyflix after it, TestFlight first
   when `BRIDGE_VERSION` grew.

### Each gate
- **Round 1, open:** every high and medium finding is fixed, or rejected or
  deferred with a written reason; lows go to the backlog.
- **Round 2, fixes only:** Codex checks the round-1 log and the fix diff. A new
  in-scope high finding is fixed; new mediums and lows go to the backlog.
- **Sign-off:** Codex checks every finding in the log: fixed (yes/no), rejection
  or deferral reason accepted (yes/contested), and whether any fix broke
  something. The gate passes only on a sign-off verdict of `approve`. A failed
  sign-off is fixed and signed off again; anything contested twice goes to
  Mark with both arguments, and his call is logged.
- **Rule:** every fix, rejection and deferral is approved by Codex or decided
  by Mark. Nothing merges with an open item.

### By kind of change
| Kind | Process |
| --- | --- |
| Feature | All of the above |
| Bug fix or small change | No spec; failing test first; Gate 2 |
| Upstream merge, no conflicts | Checks, bridge contract tests, Mac build; no review |
| Upstream merge with conflicts | Gate 2 on the conflict resolution |
| Upstream PR | The full process here, then upstream's own review |

## Consequences

- Upstream merges conflict only in the few listed seams.
- Each gate costs two review rounds and a sign-off. That cost is accepted for
  the fork's reliability; the sign-off is scoped to the log, so it ends.
- Review logs live in the PR description (and `apple/docs/reviews/` for
  docs-only phases like P0).
