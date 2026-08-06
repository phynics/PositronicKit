# PKCLEAN-002 — Split TimelinePromptHistory.swift value types into a sibling file

**Priority:** P3
**Type:** Refactor (file split, no API change)
**Depends on:** — (sequencing: land after PKDEEP2-003, or narrow — see note below)
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `6aa75ec`) — moved the 8 value types (`PromptSectionEntry`,
`PromptSnapshot`, `PromptHistorySectionKind`, `PromptHistoryJournalDiff`+`SubtreeDiff`, `PromptDiff`,
`PromptHistoryUpdate`, the `CompactionThresholds` deprecated typealias, `RegistryEvictionPolicy`)
into `TimelinePromptHistoryTypes.swift`; left the two public actors in `TimelinePromptHistory.swift`.
Pure file move, no logic or public API change. `make verify` green (925 tests / 158 suites, unchanged).

> **Sequencing note (2026-07-08):** PKDEEP2-003 deletes/replaces `CompactionThresholds`
> and may reshape `PromptDiff` / `PromptHistoryJournalDiff`. If PKDEEP2-003 is accepted,
> land this split afterwards, or narrow it to the types confirmed to survive
> (`PromptSectionEntry`, `PromptSnapshot`, `PromptHistorySectionKind`,
> `PromptHistoryUpdate`, `RegistryEvictionPolicy`). Do not run the two concurrently.

### Summary

`Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift` is 537 lines and holds 10
top-level types: 8 value/struct/enum types plus 2 public actors. Extract the value types
(snapshot, diff, thresholds, eviction policy, update) into a sibling
`TimelinePromptHistoryTypes.swift`, leaving the two actors (`TimelinePromptHistoryRegistry`,
`TimelinePromptHistory`) in the original file. Mirrors the PKARCH-006 precedent of unbundling
per-actor/value-type files (the `InMemoryStores.swift` → 8-file split).

### Current Problem

`Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift` declares, in one file:

- `PromptSectionEntry` (line 7)
- `PromptSnapshot` (line 24)
- `PromptHistorySectionKind` (line 28)
- `PromptHistoryJournalDiff<Entry>` (line 34)
- `PromptDiff` (line 60)
- `PromptHistoryUpdate` (line 111)
- `public struct CompactionThresholds` (line 118)
- `public struct RegistryEvictionPolicy` (line 132)
- `public actor TimelinePromptHistoryRegistry` (line 174)
- `public actor TimelinePromptHistory` (line 231)

The first 8 are pure value types with no actor isolation; the 2 actors are the actual stateful
components. Co-locating 10 types in one file makes the actor logic harder to scan and diverges
from the per-concern file layout used elsewhere under `Services/`.

### Implementation Requirements

1. Create `Sources/PositronicKit/Services/Prompting/TimelinePromptHistoryTypes.swift`.
2. Move the 8 value types (`PromptSectionEntry`, `PromptSnapshot`, `PromptHistorySectionKind`,
   `PromptHistoryJournalDiff`, `PromptDiff`, `PromptHistoryUpdate`, `CompactionThresholds`,
   `RegistryEvictionPolicy`) into it, preserving exact access levels and conformances.
3. Leave `TimelinePromptHistoryRegistry` and `TimelinePromptHistory` (lines 174–537) in
   `TimelinePromptHistory.swift`.
4. No logic changes — pure file move. Any `private` helper used only by the actors stays with the
   actors; any `private` helper used only by the value types moves with them.
5. Update `CHANGELOG.md` under `Unreleased` → `Changed` with a one-line internal-refactor note
   (no public API change).

### Acceptance Criteria

- [ ] `TimelinePromptHistory.swift` holds only the 2 public actors (+ their private helpers).
- [ ] `TimelinePromptHistoryTypes.swift` holds the 8 value types.
- [ ] `swift build` green.
- [ ] `swift test` green (880 tests / 155 suites baseline).
- [ ] No public API change (diff is a pure move).
- [ ] `CHANGELOG.md` `Unreleased` → `Changed` updated.
