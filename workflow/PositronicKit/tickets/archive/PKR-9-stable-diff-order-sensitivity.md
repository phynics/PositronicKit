# PKR-9 — `PromptJournalDiffer` treats stable-section reorder as a content change (spurious hard reset)

**Status:** Done
**Severity:** 🟡 Low (unnecessary cache invalidation)
**Repos:** PositronicKit (PKPrompt)
**Source:** PositronicKit review 2026-07-02

## Problem

`hasStableChanges` (`Sources/PKPrompt/Journal/PromptJournalDiffer.swift:49-56`) compares
`[SectionSignature]` arrays positionally. Same stable sections in a different order (plausible if
upstream section producers change iteration order) triggers `requiresHardReset: true`, discarding
the committed base — and any provider-side prompt cache keyed on the stable prefix — with nothing
observable changed.

## Suggested direction

Compare ID-keyed signature sets/dictionaries, or explicitly document that stable-section order is
semantically significant. Relevant to JRN-1's convergence work — decide the semantics there.

## Resolution (2026-07-04)

`hasStableChanges` (`PromptJournalDiffer.swift`) now compares stable sections as
ID-keyed dictionaries (`Dictionary(uniqueKeysWithValues: stable.map { ($0.id, SectionSignature($0)) })`)
instead of positional array equality, matching the pattern already used by
`computeSemiStableOverlay`. A pure reorder of the same stable sections no longer triggers
`requiresHardReset`; content changes, additions, and removals still do.

Added `PromptJournalDifferTests.swift` (4 tests: reorder-no-reset, content-change-reset,
addition-reset, removal-reset). Full suite green.
