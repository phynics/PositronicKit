# JRN-1 — `PromptJournal` is dead in production: two divergent journal implementations coexist

**Status:** Done — `PromptJournal` now has public append-pressure thresholds plus `recordAppend(...)`
APIs for standalone auto-compaction, the public-vs-runtime relationship is documented in
`PKPromptComposition.md`, `PositronicKitExamples` demonstrates the supported standalone flow, and
tests pin both the auto-compaction behavior and the shared semistable diff IDs with
`TimelinePromptHistory`. Verified with `swift test` (647 tests / 125 suites).
**Severity:** 🔴 High (misleading public API + design drift)
**Repos:** PositronicKit
**Source:** Journaling audit 2026-07-02

## Problem

The public `PKPrompt.PromptJournal` — documented as "the prompt-layer journaling abstraction
intended for public use" (`PromptJournal.swift:9-10`) — has **zero production callers** (verified:
only `PositronicKitExamples/PKPromptExamples.swift:104,120-122` constructs it). The live runtime
uses a parallel implementation, `TimelinePromptHistory`, which explicitly documents it is
"intentionally separate from `PKPrompt.PromptJournal`" (`TimelinePromptHistory.swift:132-142`).

The two diff algorithms diverge: `PromptJournalDiffer` buckets by `cachePolicy`
(stable/semiStable/volatile, hard reset on stable change; `PromptJournalDiffer.swift:49-56`),
while `TimelinePromptHistory.diffAndCommit` computes a purely positional stable-prefix count
(`TimelinePromptHistory.swift:395-404`). Only the latter drives real behavior (compaction,
cache-prefix reporting, inspector data). `PromptJournal` also lacks the threshold-based compaction
safety valve `TimelinePromptHistory` has (`CompactionThresholds`, `:118-128`) — its
`committedBaseSections` grow unbounded unless the caller manually `.compact()`s.

## Suggested direction

**Decision (user, 2026-07-02): `PromptJournal` stays — it remains available as a usable
context-savings tool. Do not demote or remove it.**

Direction is therefore to develop it into a first-class supported API:
- Wire `ChatEngine`/`TimelinePromptHistory` to use `PromptJournal` +
  `PromptJournalMessageRenderer` as the single diff/journal engine, converging on one diff
  semantics — or, if the runtime keeps its own path, define and document the intended standalone
  use case (context savings for direct `PKPrompt` consumers) with a real example beyond
  `PKPromptExamples`.
- Port `TimelinePromptHistory`-style compaction thresholds so `PromptJournal` has a built-in
  safety valve instead of caller-driven `.compact()` only.
- Add a test pinning the relationship between the two diff semantics (shared, or documented
  divergence).
