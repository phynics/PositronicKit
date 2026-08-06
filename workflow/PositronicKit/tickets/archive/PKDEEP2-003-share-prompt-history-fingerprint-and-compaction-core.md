# PKDEEP2-003 — Share the section-fingerprint and compaction-pressure core between the two prompt histories

**Priority:** P3
**Type:** Refactor (scoped deduplication; one design decision required)
**Depends on:** PKDEEP2-002 (corrected `publicJournalDiff` semantics)
**Blocks:** — (interacts with PKCLEAN-002 — see sequencing note)
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `1aaa58c`) — extracted `AppendPressure` (counters +
thresholds + `recordAppend`/`shouldCompact`/`reset`) and `sectionContentHash` (text-only, decision
(b): drops `estimatedTokens`/`type`, folds `role`/`think`/`isSummary` for `.messages`) into
PKPrompt, consumed by both `PromptJournal` and `TimelinePromptHistory`; post-compact action stays
consumer-specific. Runtime `CompactionThresholds` is now a deprecated typealias to
`PromptJournalCompactionThresholds` (zero downstream consumer refs). `SectionSignature` dropped
`estimatedTokens`/`type`. Token-only-change divergence eliminated; cross-system test added.
`PromptJournalDiff` not renamed (Yakamoz constraint). `make verify` green (929 tests / 159 suites).
Lands before PKCLEAN-002.

### Decision (2026-07-08) — fingerprint input policy: **(b) text-only everywhere**

Chosen over the investigation's (a) recommendation. Rationale: the fingerprint answers
"did this section change in a way the provider will notice?" — and the provider only ever
sees rendered text/messages, never our `estimatedTokens` (our own bookkeeping, derived
from the text) or our `type` enum. A token-estimate delta with identical text is an
estimator artifact, not real cache-prefix invalidation, so hashing it in is noise.
Compaction pressure is tracked separately (`recordAppend`/thresholds), so dropping tokens
from the fingerprint does not weaken compaction accounting. Adopt PKPrompt-side to the
runtime's text-only scheme (`PromptSectionEntry.contentHash`).

Implementation guardrails for (b):
- The diff is keyed by `entryId`; the fingerprint only detects content change *within* a
  given ID, so dropping `type` from the hash cannot collapse two distinct sections.
- `PromptJournalTests` semistable cases may currently assert on token-only changes —
  re-examine and update them to the text-only contract (expected: token-only change no
  longer registers as a diff).
- For `.messages` content, confirm the text-only rendering still captures
  role/`isSummary`/`think` distinctions that today enter `SectionSignature` — if a
  role/flag change is not reflected in rendered text, fold those specific fields into the
  text-only hash inputs so no *content*-bearing change is lost (only `estimatedTokens` and
  `type` are dropped).

### Summary

The 2026-07-08 investigation **rejected** the original "extract one shared diff engine"
framing: the two systems' diff algorithms are genuinely different, not duplicated.
Stable-prefix counting (front-anchored positional walk, TimelinePromptHistory.swift:444–453)
exists only runtime-side and has no PKPrompt counterpart; PKPrompt's diff is
cache-policy-partitioned (semistable overlay, stable → hard reset, volatile excluded)
while the runtime diffs all sections. PKDEEP-004's "both sides have load-bearing unique
semantics" conclusion holds for the diffs.

What **is** duplicated — and divergent in ways that can make the two systems disagree on
the same prompt — is the layer underneath: the compaction-pressure accounting (two
structurally identical threshold structs + identical `shouldCompact` expressions) and the
per-section content fingerprint (two hash schemes with different inputs). This ticket
scopes the extraction to exactly those two primitives, shared in PKPrompt, with each
system keeping its own diff algorithm and public interface. `PromptJournal` remains a
public tool (user decision JRN-1 — never demote/remove).

### Current Problem (with file:line references)

**Duplicated compaction pressure (vocabulary-only difference):**
- `Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift:118–128` —
  `public struct CompactionThresholds` (`maxAppendedTokens: 50000`,
  `maxAppendedMessages: 40`, `shouldCompact: tokens > max || messages > max`).
- `Sources/PKPrompt/Journal/PromptJournalCompactionThresholds.swift:9–21` —
  `public struct PromptJournalCompactionThresholds`: identical fields, identical
  defaults, identical `shouldCompact` expression, identical `recordAppend` delegation
  to `TokenEstimator`. A threshold bug must be found and fixed twice today.
- Post-compact behavior differs and must stay consumer-specific: PKPrompt's `compact()`
  promotes `latestObservedSections` into `committedBaseSections`; the runtime's
  `compact(hard:)` resets counters and optionally clears `baseSnapshot`. A shared
  pressure core therefore owns counters/thresholds only, with post-compact action left
  to the consumer (callback or caller-side).

**Divergent section fingerprints (real disagreement risk):**
- `TimelinePromptHistory.swift:17–21` — `PromptSectionEntry.contentHash`: Swift `Hasher`
  over the rendered text **only** (`UInt64`); ignores `estimatedTokens`, `type`, and
  per-message fields.
- `Sources/PKPrompt/Journal/PromptJournalDiffer.swift:112–145` — private
  `SectionSignature`: Swift `Hasher` over `PromptSection.Content` (for `.messages`:
  each message's `content`/`role`/`think`/`isSummary`), and its equality additionally
  includes `estimatedTokens` and `type` (`Int` hash).
- Consequence (verified): a `semiStable` section whose `estimatedTokens` changes without
  text change diffs on the PKPrompt side but **not** on the runtime side — the two
  systems return different journal diffs for the same prompt. The cross-system test
  (`TimelinePromptHistoryTests.swift:136–163`) does not cover this case.
- Note: both schemes use Swift `Hasher` (per-process seed) — fine today since neither
  snapshot persists across runs, but hash values must remain non-serialized.

**What stays where (explicitly out of scope, evidence-backed):**
- Runtime-only: stable-prefix walk + `stablePrefixTokens`, `SubtreeDiff` path
  classification, `nextInspectionTurnIndex()`, `TimelinePromptHistoryRegistry` (LRU) +
  `RegistryEvictionPolicy`, `structuredDiffHint()`/`nodeMetadata(prompt:)` bridges,
  `PromptDiff`/`PromptHistoryUpdate`.
- PKPrompt-only: `PromptJournalPlan` (base/overlay/volatile layers), `EmissionMode`,
  hard-reset policy, `buildMessages()`/`PromptJournalMessageRenderer`,
  `PromptJournalPlanBuilder`, `JournaledPromptSection`.

### Design decision required (why ready-for-human)

Unifying the fingerprint means choosing its inputs, and the choice changes runtime diff
behavior:

- **(a) Adopt SectionSignature-style inputs everywhere** (content incl. message fields +
  `estimatedTokens` + `type`): the runtime diff starts reporting token-only changes as
  `changed` — affects `stablePrefixCount` (a token-drift in a prefix section now breaks
  the prefix) and everything downstream of `PromptDiff`. More correct for cache-prefix
  reasoning; strictly more invalidation.
- **(b) Adopt text-only hashing everywhere**: PKPrompt's journal stops overlaying
  token-only changes — looser, and `PromptJournalTests` semistable cases would need
  re-examination.
- **(c) Shared fingerprint type with an explicit input-policy parameter**: both callers
  state their inputs; kills the silent divergence without forcing a semantic change, but
  keeps two behaviors (documented instead of accidental).

Recommendation from the investigation: **(a)**, since both diffs exist to answer "can a
provider cache-prefix survive?" and token drift is real invalidation pressure — but this
changes observable runtime diff output, so a human should confirm.

### Implementation Requirements

1. Record the decision (a/b/c) in this ticket, then extract into PKPrompt:
   - A single compaction-pressure core (thresholds struct + counters +
     `recordAppend`/`shouldCompact`/reset), consumed by both `PromptJournal` and
     `TimelinePromptHistory`. Keep `PromptJournalCompactionThresholds` as the surviving
     public name; `CompactionThresholds` (runtime, public) becomes a deprecated
     typealias or is migrated per the release rules — **public API check required**
     (grep consumers; PKDEEP-004 found zero downstream references, re-verify).
   - A single section-fingerprint helper (per the decision) used by
     `PromptSectionEntry` construction (`record(prompt:)`,
     TimelinePromptHistory.swift:304–318) and `SectionSignature`.
2. Type-dependency guardrail (verified feasible): the shared code may reference
   PKPrompt types (`RenderedPrompt`, `PromptSection.Content`, `CachePolicy`) and PKShared
   (`Message`, `TokenEstimator`) — PKPrompt already depends on PKShared. It must not
   reference PositronicKit runtime types (`LLMMessage` etc.).
3. Extend the cross-system test with the token-only-change case so the unified
   fingerprint is pinned (this is the case that diverges today).
4. Tests that pin the shared core and must survive (recast where they move):
   `historyUpdatesCompactWhenThresholdsExceeded`, `appendPressureAutoCompactsLatestObservation`,
   `manualCompactClearsAppendPressure`. Consumer-specific suites stay put:
   `PromptJournalDifferTests` (hard-reset policy), `buildMessages()` cases, registry LRU
   cases, `layer3*` runtime cases.
5. **PKCLEAN-002 sequencing:** that open ticket file-splits the 8 value types of
   `TimelinePromptHistory.swift`. Under this ticket, `CompactionThresholds` is
   deleted/aliased and `PromptDiff`/`PromptHistoryJournalDiff` may be reshaped —
   PKCLEAN-002 should either land **after** this ticket or be narrowed to the surviving
   types (`PromptSectionEntry`, `PromptSnapshot`, `PromptHistorySectionKind`,
   `PromptHistoryUpdate`, `RegistryEvictionPolicy`). Do not run them concurrently.
6. Downstream-sync checklist: grep Monad/Shuttle/Yakamoz for `CompactionThresholds`,
   `PromptJournalCompactionThresholds`, and any reshaped type before closing; Yakamoz
   consumes `PromptJournalDiff` via inspection DTOs (names must remain stable).
7. Update `CHANGELOG.md` (`Changed`; `Breaking`/`Deprecated` if `CompactionThresholds`
   is public-retired) and follow `docs/Releasing.md` if any public surface moves.

### Acceptance Criteria

- [ ] Fingerprint-input decision (a/b/c) recorded with rationale.
- [ ] One compaction-pressure implementation remains (in PKPrompt); both systems consume it;
      post-compact promotion/reset behavior stays consumer-specific.
- [ ] One section-fingerprint implementation remains; the token-only-change divergence is
      gone (or, under (c), explicit and tested).
- [ ] Cross-system test extended with the token-only-change case and green.
- [ ] Stable-prefix walk, SubtreeDiff, registry/eviction, plan/messages, hard-reset policy
      all byte-identical in behavior (their suites green unmodified).
- [ ] `PromptJournal` remains public and undiminished (JRN-1).
- [ ] Downstream grep recorded; consumer pins handled per release flow if public API moved.
- [ ] `make verify` green (verify executed-test count against the 880/155 baseline).
- [ ] `CHANGELOG.md` updated; PKCLEAN-002 sequencing note resolved (landed after, or narrowed).
