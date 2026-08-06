# PKPOST-002: Establish the Ongoing Semver Release Process and Downstream Upgrade Cadence

**Priority:** P2
**Type:** Process / documentation
**Depends on:** PKREL-004
**Blocks:** None
**Triage:** ready-for-human
**Status:** Done (2026-07-06)

**Resolution:** `docs/Releasing.md` added in PositronicKit `72ec444`, workspace release
flow already documented in root `CLAUDE.md`, and the `1.1.0` tag cut/pushed as the
first exercise of the documented cadence. Dry-run rehearsal clause satisfied by the
actual `1.1.0` release; consumer pins bumped in Monad `c69bdf2` and Yakamoz `e32ba28`.

### Summary

Once consumers pin `from: "1.0.0"`, define how PositronicKit changes reach them from now on:
when to cut patch/minor releases, how the local-path override flow fits development, and who
bumps consumer pins. Without this, the workspace silently drifts back to "push to main and
hope" — the failure mode the v1 pin was meant to end.

### Deliverables

1. A short `docs/Releasing.md` in PositronicKit covering: version-bump rules (semver mapped to
   the public products), tagging steps, changelog discipline (`Unreleased` section required in
   every behavioral PR), and the verification matrix that must pass before any tag.
2. Updated workspace guidance (root `CLAUDE.md`): the default development flow for cross-repo
   changes becomes — local-path override while developing → land in PositronicKit → tag a
   patch/minor → bump consumer pins in the same ticket that needed the change.
3. Decide and document the upgrade cadence for consumers not driving a change (e.g. bump
   Monad/Shuttle/Yakamoz pins opportunistically per minor release; each bump runs that
   consumer's full gate).
4. Fold the downstream-sync checklist into the new flow (grep all three consumers, GRDB
   migration check, reviewer prompt) — the checklist survives; only the "push to remote main
   first" step changes.

### Acceptance Criteria

- [ ] `docs/Releasing.md` exists and matches what PKREL-004 actually did.
- [ ] Root `CLAUDE.md` and the downstream-sync checklist plan are updated consistently.
- [ ] A dry-run patch release (e.g. `1.0.1` with a docs-only change) has exercised the
      documented steps end to end.
