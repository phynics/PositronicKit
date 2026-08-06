# PKDEEP2-002 — publicJournalDiff leaks non-semistable IDs into PromptJournalDiff

**Priority:** P2
**Type:** Bug (behavioral fix, no API signature change; downstream display impact in Yakamoz)
**Depends on:** —
**Blocks:** PKDEEP2-003 (the shared-core ticket should build on corrected semantics)
**Triage:** ready-for-agent
**Status:** Done — `PromptHistoryJournalDiff.removed` carries `Entry` values so policy is preserved; `publicJournalDiff` filters to `cachePolicy == .semiStable`; mixed-policy regression tests added and cross-system agreement test extended; downstream grep clean across Monad/Shuttle/Yakamoz. Merged `39f0b18`; `make verify` green (896 tests / 156 suites).

### Summary

`PromptDiff.publicJournalDiff` projects the runtime diff into `PromptJournalDiff`, whose
fields are named `changedSemiStableIDs` / `addedSemiStableIDs` / `removedSemiStableIDs` —
but the runtime diff classifies **all** sections regardless of `cachePolicy`, so stable
and volatile section IDs flow into fields that contractually carry only semistable IDs.
This projection is what `TurnLoopController` publishes as `TurnJournalSnapshot.overlay`
to `TurnInspecting`, and Yakamoz's `JournalInspectorView` renders those IDs as semistable
changes — so the inspector misreports stable/volatile churn as overlay activity. Found by
the 2026-07-08 architecture-review investigation of the prompt-history duality.

### Current Problem (with file:line references)

- `Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift:102–108`:
  ```swift
  var publicJournalDiff: PromptJournalDiff {
      PromptJournalDiff(
          changedSemiStableIDs: changed.map(\.entryId),
          addedSemiStableIDs: added.map(\.entryId),
          removedSemiStableIDs: removed
      )
  }
  ```
  `PromptDiff.changed` / `.added` / `.removed` are populated by `diffAndCommit`
  (TimelinePromptHistory.swift:455–483), which walks **all** snapshot entries with no
  `cachePolicy` partition. Contrast PKPrompt's `PromptJournalDiffer`, where the diff is
  computed **only** over `semiStable` sections (stable changes → hard reset; volatile
  sections never enter the diff).
- Consumer chain: `TurnLoopController.swift:257` (`overlay: diff.publicJournalDiff`) →
  `TurnJournalSnapshot.overlay` (`TurnInspecting.swift:68,72`, public) →
  Yakamoz `SwiftDataTurnInspector` → `JournalInspectorProjection.swift` /
  `JournalInspectorView.swift`, which display the IDs as semistable overlay entries.
- Test coverage: exactly one direct assertion —
  `TimelinePromptHistoryTests.swift:161` (`journalPlan.diff == runtimeDiff.publicJournalDiff`)
  on a prompt with a single `semiStable` section, so the leak case (stable or volatile
  change present) is never exercised. That is why the two systems appear to agree.

### Implementation Requirements

1. Filter the projection to semistable entries. `PromptSectionEntry` already carries
   `cachePolicy`, so `changed`/`added` can filter directly:
   ```swift
   var publicJournalDiff: PromptJournalDiff {
       PromptJournalDiff(
           changedSemiStableIDs: changed.filter { $0.cachePolicy == .semiStable }.map(\.entryId),
           addedSemiStableIDs: added.filter { $0.cachePolicy == .semiStable }.map(\.entryId),
           removedSemiStableIDs: /* see requirement 2 */
       )
   }
   ```
2. `removed` is `[String]` (bare IDs) — the policy of a removed section must come from
   the **previous** snapshot's entries. Either carry `removed` as `[PromptSectionEntry]`
   (preferred: preserves policy + tokens for future use; internal type, no API impact)
   or capture a `removedSemiStableIDs` array at diff time inside `diffAndCommit`, where
   `previousById` still has the entries in scope.
3. Do **not** change `PromptDiff.changed/added/removed` semantics themselves — the
   all-policy diff feeds `stablePrefixCount`/`SubtreeDiff` and is load-bearing for the
   runtime. Only the projection into the journal vocabulary narrows.
4. **Tests:**
   - New case in `TimelinePromptHistoryTests`: a prompt where a `stable` section, a
     `volatile` section, and a `semiStable` section all change between updates —
     assert `publicJournalDiff` contains only the semistable ID in each field.
   - Extend the cross-system test
     (`promptJournalAndRuntimeHistoryShareSemistableDiffIDs`, :136–163) with the mixed-
     policy prompt so runtime and PKPrompt journal actually agree in the presence of
     stable/volatile churn.
   - A removal case: semistable section removed + stable section removed → only the
     semistable ID appears in `removedSemiStableIDs`.
5. **Downstream check (all three consumers):** no API signature changes;
   Yakamoz consumes the corrected values through `TurnJournalSnapshot.overlay`
   (behavioral improvement for `JournalInspectorView`). Yakamoz tests that construct
   `PromptJournalDiff(...)` directly (`ChatViewModelTests`, `RuntimeCompositionTests`,
   `JournalInspectorProjectionTests`, `TurnInspectionProjectionTests`,
   `InspectionViewModelTests`, `InspectableChatIntegrationTests`) are unaffected —
   grep to confirm, per the downstream-sync checklist. Monad/Shuttle have zero journal
   references (verified 2026-07-08).
6. Update `CHANGELOG.md` under `Unreleased` → `Fixed`.

### Acceptance Criteria

- [ ] `publicJournalDiff` emits only `cachePolicy == .semiStable` IDs in all three fields.
- [ ] Mixed-policy regression tests added (changed/added/removed leak cases).
- [ ] Cross-system agreement test extended to a mixed-policy prompt and green.
- [ ] Runtime `PromptDiff` all-policy semantics (stable prefix, subtree diff) unchanged —
      existing `TimelinePromptHistoryTests` suite green without modification except the
      extended cases.
- [ ] Downstream grep of Monad/Shuttle/Yakamoz recorded in the resolution note.
- [ ] `make verify` green (880 tests / 155 suites baseline + new cases; verify tests ran).
- [ ] `CHANGELOG.md` `Unreleased` → `Fixed` updated.
