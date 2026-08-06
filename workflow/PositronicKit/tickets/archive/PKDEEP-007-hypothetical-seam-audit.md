# PKDEEP-007 — Audit and honestly label hypothetical protocol seams (one adapter each)

**Priority:** P3
**Type:** Research / architecture cross-cutting follow-up (deepening tracking ticket)
**Depends on:** none (folds naturally with PKDEEP-001, PKDEEP-002, PKDEEP-003; standalone only for audit, not for action)
**Blocks:** none
**Triage:** ready-for-agent
**Status:** Done (2026-07-08) — all child tickets resolved, audit table recorded

### Summary

Four protocols in `PositronicKit/` each have exactly one production adapter whose interface
mirrors that adapter — the canonical "one adapter = hypothetical seam" pattern. They were
introduced as test seams (legitimate motivation), but they cannot evolve independently
because they track one conformer. This ticket is a **cross-cutting audit**, not a single
implementation: it confirms the one-adapter state for each protocol, labels the seam
honestly, and folds each into its corresponding implementation ticket (PKDEEP-001,
PKDEEP-002, PKDEEP-003) where applicable. Real seams with two or more adapters are
explicitly marked "keep".

### Current problem (with file:line references)

- `Sources/PositronicKit/Protocols/TurnInspecting.swift` — sole production adapter is
  `Yakamoz/Sources/YakamozCore/Inspection/SwiftDataTurnInspector.swift`. A single-customer
  observability hook.
- `Sources/PositronicKit/Services/Tools/ToolRoutingDecision.swift` defines
  `WorkspaceResolutionProvider` — sole production adapter is `TimelineManager` via an
  extension in the same file (mirrors `getWorkspaces(for:)`, `getWorkspace(_:)`,
  `findWorkspaceForTool(_:in:)`, `getTimeline(id:)`, `getToolManager(for:)`). Plus a test
  fake. Fold candidate with PKDEEP-003.
- `Sources/PositronicKit/Services/Timeline/TimelineCache.swift` — sole production adapter
  is `TimelineManager`; plus `Tests/PositronicKitTests/Services/FakeTimelineCache.swift`.
  Fold candidate with PKDEEP-002.
- `Sources/PositronicKit/Services/Prompting/PromptAssembly.swift` defines
  `PromptAssemblyStage` — sole conformers are the 10 stages inside
  `PromptAssemblyStages.swift`; no external or local adapter. Fold candidate with
  PKDEEP-001.

**Real seams (contrast — these earn their keep):**
- `KeyValueStoreProtocol` — `InMemoryKeyValueStore` (PositronicKit) + Monad's
  `DatabaseKeyValueStore`. Two production adapters.
- `EmbeddingServiceProtocol` — `NoOpEmbeddingService` + `LocalEmbeddingService` (plus
  per-provider fakes). 2+ adapters.
- `LLMStreamClient` — OpenAI, OpenRouter, Ollama, Anthropic, Foundation Models. Many
  adapters.
- `ChatTurnPlugin` — Yakamoz's `AutonomousFollowUpPlugin`. Real external adapter.
- `PromptSectionProviding` — Yakamoz's `CurrentTimeSectionProvider`. Real external adapter.

### Research scope

1. **Re-confirm adapter counts.** Grep the workspace for conformers of each of:
   `TurnInspecting`, `WorkspaceResolutionProvider`, `TimelineCache`,
   `PromptAssemblyStage`. Record production-adapter count + test-fake count for each.
   If any protocol has since grown a second production adapter while the review was
   pending, its status flips to "real seam — keep" and it's removed from this ticket's
   scope.
2. **Per-protocol decision:**
   - **`TurnInspecting`** — Recommend **keep** with a documenting note. It's an
     intentional single-customer hook (Yakamoz's persistence need); the "one adapter"
     pattern is deliberate, not hypothetical. Verify the doc comment on
     `TurnInspecting` reflects "single-customer observability hook" so future reviewers
     don't re-flag it.
   - **`WorkspaceResolutionProvider`** — Delegate to PKDEEP-003 step 2 (the adapter
     audit there). If PKDEEP-003 impl lands and folds the helper, this protocol retires
     with it.
   - **`TimelineCache`** — Delegate to PKDEEP-002 step 2 (the adapter audit there). If
     PKDEEP-002 impl lands and folds the helper, this protocol retires with it.
   - **`PromptAssemblyStage`** — Delegate to PKDEEP-001 step 1 (the workspace-wide grep
     for conformers). If PKDEEP-001 impl lands, this protocol retires with it.
3. **Real-seam audit (sanity check).** Confirm `KeyValueStoreProtocol`,
   `EmbeddingServiceProtocol`, `LLMStreamClient`, `ChatTurnPlugin`,
   `PromptSectionProviding` still have ≥2 production adapters as of this research; record
   the list per protocol so the audit table in the report stays accurate.
4. **Documentation follow-up.** Wherever a single-adapter protocol is kept with intent
   (e.g. `TurnInspecting`), ensure the protocol's doc comment explicitly says
   "intentional single-customer hook — do not generalize without a second adapter" (or
   similar) so future `/improve-codebase-architecture` runs don't re-flag it. This is a
   small documentation slice that can land even if no helper-fold tickets proceed.
5. **Cross-ticket dependency map.** Record: PKDEEP-007 is **closed** when its child
   tickets (PKDEEP-001, PKDEEP-002, PKDEEP-003) resolve the three fold-able protocols, OR
   when each of those children rejects the fold with a load-bearing reason (in which case
   the protocol stays and the reason is recorded in an ADR).

### Acceptance criteria

- [x] Adapter counts confirmed for each of the four hypothetical-seam protocols; the
      "real seam" contrast list re-verified.
- [x] Per-protocol decision recorded: fold (with the owning child ticket) **or** keep
      (intentional) **or** widen (plan a second adapter, with the planned adapter named).
- [x] For any kept-with-intent protocol, the doc comment is updated to explicitly say
      "intentional single-customer hook" (or equivalent), shipped as a small standalone
      doc PR if no child ticket lands.
- [x] Cross-ticket dependency map recorded: PKDEEP-007 closes when
      PKDEEP-001/002/003 resolve their respective folds (or reject with ADRs).
- [x] Final finding: this ticket produces a documented audit table; per-protocol
      outcomes are tracked via child tickets (PKDEEP-001/002/003) — PKDEEP-007 itself
      does not carry implementation.
- [x] On close, the audit table is appended to the README's `PKDEEP` series context line
      so the seam status is part of the project's permanent record.

### Audit findings (2026-07-08)

#### Hypothetical-seam protocols (audited)

| Protocol | Status | Production Adapters | Test Fakes | Decision | Resolved By |
|----------|--------|-------------------|------------|----------|-------------|
| `PromptAssemblyStage` | **Retired** | 0 (was 10 internal stages) | 0 | Folded — deleted | PKDEEP-001-impl (`d457bd4`) |
| `TimelineCache` | **Retired** | 1 (`TimelineManager`) | 1 (`FakeTimelineCache`) | Folded — deleted | PKDEEP-002-impl (`6c71c60`) |
| `WorkspaceResolutionProvider` | **Retired** | 1 (`TimelineManager`) | 1 (`FakeProvider`) | Folded — deleted | PKDEEP-003-impl (`cb85a09`) |
| `TurnInspecting` | **Kept** | 1 (`SwiftDataTurnInspector` in Yakamoz) | 0 | Intentional single-customer hook — doc comment updated | This ticket |

Zero references to `PromptAssemblyStage`, `TimelineCache`, or `WorkspaceResolutionProvider`
remain in the codebase (confirmed by grep).

`TurnInspecting` doc comment updated in
`Sources/PositronicKit/Protocols/TurnInspecting.swift` to explicitly say:
"Intentional single-customer extension point: the sole production adapter is Yakamoz's
`SwiftDataTurnInspector`. Do not generalize without a second adapter."

#### Real-seam contrast list (re-verified)

| Protocol | Production Adapters | Status |
|----------|-------------------|--------|
| `KeyValueStoreProtocol` | `InMemoryKeyValueStore` (PositronicKit) + `DatabaseKeyValueStore` (Monad) | Real seam — 2 adapters ✓ |
| `EmbeddingServiceProtocol` | `NoOpEmbeddingService` + `LocalEmbeddingService` + `OpenAIEmbeddingService` | Real seam — 3 adapters ✓ |
| `LLMStreamClient` | OpenAI, OpenRouter, Ollama, Anthropic, Foundation Models | Real seam — 5 adapters ✓ |
| `ChatTurnPlugin` | 0 current conformers (ticket referenced `AutonomousFollowUpPlugin`, since removed) | Public extension point — keep (designed pluggability, not a test seam) |
| `PromptSectionProviding` | 1 (`CurrentTimeSectionProvider` in Yakamoz) | Real external adapter — keep ✓ |

#### Cross-ticket dependency map

- PKDEEP-001-impl → retired `PromptAssemblyStage` ✓
- PKDEEP-002-impl → retired `TimelineCache` ✓
- PKDEEP-003-impl → retired `WorkspaceResolutionProvider` ✓
- PKDEEP-007 (this ticket) → `TurnInspecting` doc comment updated, audit table recorded ✓

**All child tickets resolved. PKDEEP-007 closed.**

### Downstream sync

Research and small doc-comment updates only. No public API changes from this ticket
directly; any retirements flow through the child tickets' downstream-sync gates.