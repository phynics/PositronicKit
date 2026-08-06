# JRN-4 — Journal tab view logic (volatile filtering, turn navigation) untested

**Status:** Done
**Severity:** 🟠 Medium (untested UI logic; YAK-16 regression surface)
**Repos:** Yakamoz
**Source:** Journaling audit 2026-07-02

## Problem

`JournalInspectorView` has no tests (verified by grep over `Yakamoz/Tests`). Two pieces of pure
logic live inside the SwiftUI view: `volatileSections` (flattening `sectionTree` and intersecting
IDs, `JournalInspectorView.swift:91-111`) and prev/next turn navigation bounds
(`canSelectTurn`/`onSelectTurn`, `:42-66`). Existing coverage (`InspectionViewModelTests`,
`TurnInspectionProjectionTests`) tests the DTO layer below, not this filtering — the exact area
where YAK-16 ("everything marked volatile") previously regressed.

## Suggested direction

Extract the volatile-section filter into a testable helper (mirroring `InspectionViewModel`'s
testing pattern) and unit-test the ID-intersection behavior plus navigation bounds edges (turn 0
"previous" disabled; last turn "next" disabled).

## Resolution (2026-07-04)

Extracted both pieces of pure logic out of `JournalInspectorView` into `YakamozCore` as
`Sendable` value types mirroring the `InspectionViewModel`/`CompressionSummary` testing
pattern, and the view now delegates to them:

- `JournalInspectorProjection` (`Sources/YakamozCore/Inspection/JournalInspectorProjection.swift`)
  — depth-first tree flatten (`flatten(_:)`) + volatile-section intersection against
  `changedSemiStableIDs ∪ addedSemiStableIDs`. Exposed via `flatSections`/`volatileSections`.
- `TurnNavigationBounds` — `current ± 1` index derivation + `canSelectPrevious`/`canSelectNext`
  wiring over the host's injected selection predicate (the transcript-derived predicate itself
  stays in `ChatViewModel.canSelectInspectionTurn`, which already has its own coverage).

Tests (`Tests/YakamozTests/JournalInspectorProjectionTests.swift`, 9 cases) pin the
YAK-16 regression surface directly: empty diff → no volatile sections (not "everything
volatile"); changed ID outside the tree ignored (intersection, not union); an ID under
both `changed` and `added` appears once; volatile output preserves tree order; nested
children match via the flatten; plus the navigation edges (turn 0 previous → -1 rejected;
last turn next → one-past-end rejected; predicate delegation).

`make verify` green: 289 tests, 33 suites.

### Incidental downstream fix

Resolving JRN-4 surfaced a separate downstream break from PositronicKit/main's new sidecar
events (`.delta(.sidecar)`, `.completion(.sidecarsCompleted)`): `ChatEventReducer.reduce`'s
switch became non-exhaustive and the package would not build. Yakamoz does not yet consume
sidecar state (tracked under the SDC series), so the reducer now no-ops those cases — mirroring
the existing `.delta(.thinking)`/`.delta(.generation)` breaks — committed separately as
`fix(downstream): handle new sidecar ChatEvent cases in reducer`.
