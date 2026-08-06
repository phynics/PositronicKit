# PKAPI-015 — Rename `TurnInspecting` → `PromptInspecting` (name the payload, not just the phase)

**Priority:** P3
**Type:** Public API rename
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, PositronicKit commit `35cce94`)

**Resolution:** Renamed `TurnInspecting`→`PromptInspecting`, `didComposeTurn`→`didComposePrompt`,
`TurnInspection`→`PromptInspection`, `turnInspector`→`promptInspector`, `ExampleTurnInspector`→
`ExamplePromptInspector`; renamed both files; carried the PKCLEAN-011 seam docstring forward.
Shared correlation types (`TurnIdentity`, `TurnJournalSnapshot`) left unchanged. CHANGELOG updated.
PK build clean; the 6-test `PromptInspectingTests` suite passes. Yakamoz's conformer renamed to
`SwiftDataPromptInspector` and PK-facing wiring updated in its working tree — Yakamoz's own
`TurnInspectionModel`/`PersistedTurnInspection` (SwiftData `@Model`/DTO, Yakamoz-internal) left as-is
to avoid a persistence migration outside this rename's scope. Yakamoz commit + `make verify` are a
release-gated follow-up (per the workspace release flow, Yakamoz can't build against the unreleased PK
change until a compatible tag is cut).

Supersedes the naming portion of [PKCLEAN-011](PKCLEAN-011-clarify-turninspecting-chatturnplugin-seam.md)
(decision there: keep two protocols, docs-only, rejected `TurnObserving`). This ticket revisits *only*
the name, decided in a follow-up user conversation 2026-07-09 alongside the PKFAC facade-redesign
brainstorm.

### Summary

`TurnInspecting`/`ChatTurnPlugin` read as the same seam from outside the package because both are
"protocol conforming type registered on the facade, called once per turn." PKCLEAN-011 already fixed
this with cross-referencing docstrings (landed) and correctly rejected `TurnObserving` — it optimizes
the read/write axis when the *name* should optimize whichever axis a reader needs at a glance.

Renaming to `PreflightInspecting` was considered and rejected in favor of **`PromptInspecting`**: the
payload (`TurnInspection` → `PromptInspection`) is the fully composed, about-to-be-sent prompt
(rendered prompt + sent messages + journal diff, no response yet) — the name should say *what you
receive*, not just *when*. `PromptInspecting` also reads unambiguously distinct from `ChatTurnPlugin`
(one inspects the prompt going in; the other plugs into the turn coming out), which was the actual
goal PKCLEAN-011 was chasing.

### Rename map

| Old | New |
|---|---|
| `protocol TurnInspecting` | `protocol PromptInspecting` |
| `func didComposeTurn(_ inspection: TurnInspection)` | `func didComposePrompt(_ inspection: PromptInspection)` |
| `struct TurnInspection` | `struct PromptInspection` |
| `turnInspector` (param/property, all sites) | `promptInspector` |
| `ExampleTurnInspector` (examples) | `ExamplePromptInspector` |

`TurnIdentity` / `TurnJournalSnapshot` (in the same file) are unaffected — they're shared correlation
types, not part of this seam's name collision.

### Current call sites (confirmed via grep, 2026-07-09)

- `Sources/PositronicKit/Protocols/TurnInspecting.swift` — the protocol + payload types (file itself
  should be renamed to `PromptInspecting.swift`).
- `Sources/PositronicKit/PositronicKit.swift:44,83,89,120,144,159,203,234,272` — stored property, init
  param (both inits), doc comment, `reconfigured`/`addPlugin` copy sites. **Note:** PKFAC-001 is
  converting this file's `struct` to a `final class` and dropping the copy-based `reconfigured`/`addPlugin`
  pattern — sequence this rename to land *after* PKFAC-001 to avoid rebasing through that structural
  change, or do both in the same pass if picked up together.
- `Sources/PositronicKit/PositronicKit+Configuration.swift:60,71,87,111,119,126,157` — grouped
  `RuntimeConfiguration`.
- `Sources/PositronicKit/Services/Chat/ChatEngine.swift:93,105,117` — `ChatEngine.Dependencies`.
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnLoop.swift:251,276` — the actual call site
  (`inspector.didComposeTurn(TurnInspection(...))`).
- `Sources/PositronicKitExamples/PositronicKitUsageExamples.swift:12,17,26,29` — `ExampleTurnInspector`
  conformer + `makeInspectableRuntime`.
- `Tests/PositronicKitTests/TurnInspectingTests.swift` — rename file + suite to `PromptInspectingTests`.
- Downstream: **Yakamoz** owns the only real production conformer, `SwiftDataTurnInspector` — grep and
  update per the downstream-sync checklist.

### Implementation Requirements

- [ ] Rename protocol, payload struct, method, and all stored properties/params per the table above.
- [ ] Rename `TurnInspecting.swift` → `PromptInspecting.swift`, `TurnInspectingTests.swift` →
      `PromptInspectingTests.swift`.
- [ ] Carry forward the existing docstring content (compose-time-vs-complete-time distinction,
      cross-reference to `ChatTurnPlugin`, "do not generalize without a second adapter" note) — update
      wording to `PromptInspecting`/`didComposePrompt` but keep the substance PKCLEAN-011 already wrote.
- [ ] Update `PositronicKitExamples` (`ExampleTurnInspector` → `ExamplePromptInspector`,
      `makeInspectableRuntime`).
- [ ] Downstream: update Yakamoz's `SwiftDataTurnInspector` conformer and its facade wiring
      (`turnInspector:` → `promptInspector:`) via the local-path override; grep Monad/Shuttle too in case
      either references the type even without conforming.
- [ ] CHANGELOG entry (public API rename).

### Acceptance Criteria

- [ ] No remaining references to `TurnInspecting`/`TurnInspection`/`didComposeTurn`/`turnInspector`
      anywhere in the four repos.
- [ ] `PromptInspecting`'s docstring explains the seam and cross-references `ChatTurnPlugin`, same
      substance as the PKCLEAN-011 docstring it replaces.
- [ ] Yakamoz's conformer renamed and its tests pass.
- [ ] `make verify` green in PositronicKit; Yakamoz `make verify` green.
