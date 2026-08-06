---
Priority: P2
Type: Refactoring / parameter list reduction
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: High
Owner: —
Effort: M
Review: Code review 2026-07-29
Pinned revision: a354632
Resolution: Completed 2026-07-29. Added internal KitDependencies wiring and centralized facade
reconstruction for reconfigured, addingStage, and addingPlugin while preserving public APIs.
Full verification passed with 1610 tests in 238 suites.
---

# PKCR-009 — Introduce KitDependencies struct to reduce PositronicKit.init parameter list (21 params)

## Summary

`PositronicKit.init` takes 21 parameters — the longest parameter list in the codebase. The builder methods (`reconfigured`, `addingStage`, `addingPlugin`) each repeat the same ~25-line parameter forwarding, creating maintenance burden and fragility.

## Current problem

- `Sources/PositronicKit/PositronicKit.swift:117-139` — designated init with 21 parameters.
- `Sources/PositronicKit/PositronicKit.swift` — `reconfigured(...)`, `addingStage(...)`, `addingPlugin(...)` each reconstruct `PositronicKit` with nearly identical parameter forwarding.

## Implementation requirements

1. Create an internal `KitDependencies` struct (or similar) that bundles the resolved stores, managers, and configuration passed to `PositronicKit.init`.
2. The designated init populates it once.
3. `reconfigured(...)`, `addingStage(...)`, `addingPlugin(...)` mutate one field of the struct and forward it.
4. Keep the public API surface unchanged — the grouped `Configuration` init (`PositronicKit(configuration:)`) already exists; this is an internal refactoring.
5. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [ ] `KitDependencies` (or equivalent) struct introduced internally.
- [ ] Builder methods (`reconfigured`, `addingStage`, `addingPlugin`) forward the struct instead of repeating 20+ parameters.
- [ ] Public API surface unchanged.
- [ ] `swift build` succeeds.
- [ ] `swift test` passes (1598+ tests).
- [ ] `CHANGELOG.md` updated.
