---
Priority: P1
Type: API design
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Resolution: Completed 2026-08-04 in PositronicKit 7aeb3ca. Added explicit prompt APIs and
  compatibility shims, resolved token-budget overload ambiguity, and verified the 3.4.0 gates.
Confidence: High
Owner: —
Effort: L
Review: Swift API Design Guidelines review 2026-08-04
Pinned revision: ebd61d5
---

# PKAPI-002 — Improve PKPrompt API fluency

## Summary

Replace ambiguous Boolean and non-fluent prompt APIs with explicit, source-compatible canonical
forms while retaining deprecated forwarding shims.

## Current problem

- `CompressionStrategy.truncate(tail:)` and `CompressionAction.truncate(limit:tail:)` invert easily.
- `PromptJournal.reset(hard:)` hides whether the committed base is discarded.
- `ForEach(data:content:)` contradicts its documented `ForEach(elements)` shape and its public
  closure parameter has no role name.
- `TokenBudget.apply`, `applyWithReport`, and `budget(to:)` form a repetitive, non-fluent family.
- Public compression types spell `nodeId` while the module otherwise uses `ID`.

## Implementation requirements

1. Add an explicit truncation direction/retention type and canonical
   `.truncate(keeping:)` / `.truncate(limit:keeping:)` forms; retain the Boolean enum cases for
   exhaustive-switch and synthesized-Codable compatibility. Do not availability-deprecate those
   cases because the canonical factories must construct them and the package verification gate is
   expected to remain warning-clean; document them as legacy compatibility surface instead.
2. Add explicit journal operations for retaining versus discarding committed state; deprecate
   `reset(hard:)` as a forwarding shim.
3. Add `ForEach(_ elements:content:)` with a named closure parameter; deprecate
   `init(data:content:)` and update docs/examples.
4. Add one canonical side-effect-free token-budget API with defaults and a structured result;
   retain existing methods as deprecated projections/forwarders.
5. Make `nodeID` canonical on `CompressionNodeReport`, `SummaryRequest`, and
   `PlannedNodeAction`; retain deprecated `nodeId` aliases/initializers and preserve existing
   encoded keys explicitly.
6. Update all internal and representative downstream call sites and tests.
7. Add compatibility and wire-format tests.
8. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [x] Canonical prompt calls communicate truncation/reset/token-budget semantics without Boolean ambiguity.
- [x] Existing public calls remain source-compatible through deprecated shims.
- [x] Existing encoded keys and decode behavior remain compatible.
- [x] PKPrompt and integration tests pass.
- [x] Monad, Shuttle, and Yakamoz audits are recorded.
- [x] `CHANGELOG.md` is updated.

## Verification and downstream audit

- Added explicit empty-array coverage for `result(forPrompts:)` and
  `result(forResolvedSections:)`; legacy overloads remain one-way shims.
- `make verify`: passed, 1,637 tests in 242 suites. All other release gates passed.
- Monad, Shuttle, and Yakamoz were searched for the affected PKPrompt symbols. Their released pins
  and existing calls remain compatible, so no downstream edit was required.
