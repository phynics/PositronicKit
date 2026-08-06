# PKCLEAN-009 — Build-surface housekeeping: Examples test dependency, PKFastEmbed product

**Priority:** P3
**Type:** Housekeeping
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `4c63ad9`, merged `818e71f`) — item 1 (`PositronicKitExamples`
test dependency): kept, with a justifying comment added to `Package.swift` — the
`Tests/PositronicKitTests/Stories/Examples/*.swift` files exercise `PKPromptExamples`/
`PositronicKitUsageExamples` behaviorally (not a trivial compile check), so dropping the dependency
would lose coverage rather than relocate it. Item 2 (`PKFastEmbed` product): ticket's premise was
stale — re-checked `Package.swift`'s `products:` array and `PKFastEmbed` was never declared there
(target-only already); no change needed. `swift build`/`swift test` green (926 tests / 159 suites).
CHANGELOG updated.

### Summary

Two Package.swift surface items:

1. `PositronicKitExamples` is a product **and** a dependency of `PositronicKitTests`,
   so the full example executable (linking all five providers + embeddings) compiles on
   every `swift test`. Its imports from tests are minimal. Decouple: drop the test-target
   dependency (move any compile-check value into the existing `Stories/` tests) and
   consider demoting it from a declared product (per AGENTS.md, `make verify` docs gates
   may reference it — check `Makefile`/`llms.txt` first).
2. `PKFastEmbed` is declared as a standalone library product although it is an internal
   implementation detail of `PKLocalEmbeddings`; no consumer imports it directly
   (verified against Monad/Shuttle/Yakamoz). Remove the product declaration, keep the
   target.

### Acceptance Criteria

- [ ] `swift test` no longer builds `PositronicKitExamples` (or the dependency is
      justified in a comment).
- [ ] `PKFastEmbed` no longer a public product; target intact; `make verify-minilm`
      unaffected.
- [ ] `make verify` + `make verify-products` green (update `Makefile` `PRODUCTS` list if
      needed); CHANGELOG updated.
