# PKAPI-013 — Ambiguous/underdocumented Bool parameters: `dryRun` on store protocols, `reset(hard:)` on PromptJournal

**Priority:** P3
**Type:** Documentation / API design
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, commit `7f626af`, merged into `main`) — documented the `dryRun: Bool`
contract on all four `prune*` protocol requirements (`MessageStoreProtocol`,
`TimelinePersistenceProtocol`, `MemoryStoreProtocol` ×2): `dryRun: true` returns the count that
would be deleted without mutating persisted state. Verified every in-package conformer
(`InMemory*` stores, `PKTestSupport`'s `Mock*` stores) — all currently no-op `prune*` unconditionally
returning `0`, so the contract trivially held but was unpinned; added
`Tests/PositronicKitTests/Services/PruneDryRunTests.swift` (8 tests) to pin it down. `reset(hard:)`:
kept documentation-only (tightened the existing comment) — grepped the whole workspace and found
zero call sites outside `PromptJournal`'s own definition, so no real confusion existed to justify an
enum/split-method reshape, per the ticket's own guidance. `swift test` green (940 tests / 160
suites, +8 from the new suite). CHANGELOG updated (Changed, docs-only).

### Summary

Same pattern as the already-ticketed `chatStream(useUtilityModel:useFastModel:)` booleans
(PKAPI-007), found in two more places:

1. **`dryRun: Bool` is undocumented on every pruning method** across three store
   protocols:
   - `MessageStoreProtocol.pruneMessages(olderThan:dryRun:)`
     (`Sources/PositronicKit/Services/Database/MessageStoreProtocol.swift:11`)
   - `TimelinePersistenceProtocol.pruneTimelines(olderThan:excluding:dryRun:)`
     (`Sources/PositronicKit/Services/Database/TimelinePersistenceProtocol.swift:12-15`)
   - `MemoryStoreProtocol.pruneMemories(matching:dryRun:)` and
     `pruneMemories(olderThan:dryRun:)`
     (`Sources/PositronicKit/Services/Database/MemoryStoreProtocol.swift:21-22`)

   The presumed contract — `dryRun: true` returns the count of rows that *would* be
   deleted without deleting them — is never stated, and each returns a bare `Int` whose
   meaning flips with the flag. A conformer implementing these from the protocol alone
   has to guess.
2. **`PromptJournal.reset(hard: Bool = false)`**
   (`Sources/PKPrompt/Journal/PromptJournal.swift:108`) — unlike `dryRun`, this one *is*
   documented ("- Parameter hard: When `true`, also clears the committed base…"), so the
   original agent report overstated it. The residual issue is call-site readability:
   `journal.reset(hard: true)` doesn't convey "also clear the committed base" without
   reading the docs. Lower priority; an enum (`reset(.observationOnly)` /
   `.includingCommittedBase`) or a second method would fix it, but documentation-only is
   an acceptable outcome here.

### Implementation Requirements

- [ ] Add doc comments to all four `prune*` protocol requirements stating the `dryRun`
      contract explicitly, including what the returned `Int` means in each mode, and
      whether conformers may have side effects (e.g. logging) in dry-run mode.
- [ ] Verify the in-memory stores and PKTestSupport mocks actually honor the documented
      contract (dry run really doesn't delete) — add a test per store if missing.
- [ ] For `reset(hard:)`: decide documentation-only vs. enum/split-method; record the
      decision in the ticket resolution. Don't force a breaking change for a documented
      default-false flag unless call sites show real confusion.

### Acceptance Criteria

- [ ] `dryRun` contract documented on all store protocol requirements; conformance
      behavior tested.
- [ ] `reset(hard:)` decision recorded (keep-with-docs or reshape).
- [ ] `make verify` green.
