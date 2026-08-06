# PKV3-007 — Remove compatibility and implementation-leak surface

**Priority:** P1
**Type:** Breaking API cleanup
**Depends on:** —
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done for the scope landed; legacy `LLMConfiguration` split to
[PKV3-014](PKV3-014-llmconfiguration-legacy-compat-removal.md) (2026-07-13, PositronicKit
`b7af773`)

**Resolution:** Deleted the deprecated `CompactionThresholds` typealias (unused, no call
sites) and `EmptySection` typealias (1 test migrated to `EmptyPrompt` directly). Deleted
`TimelineManager.getTimeline(id:)`; call sites migrated to `timeline(id:)` (pure lookup) or
`touchTimeline(id:)` + `timeline(id:)` where the touch-on-read side effect had to be preserved
(`ChatEngine+TurnPreparation`, `TimelineManagerTests`, `AgentInstanceManagerTests`,
`SessionManagerConcurrencyTests`, and downstream Monad's `ChatAPIController`/
`TimelineAPIController`, migrated ahead of the pin bump per Monad's own "migrate call sites
together" convention). Lowered `StreamingParser` from public to internal after grepping
Monad/Shuttle/Yakamoz source and finding no external consumer. `VectorMath` and `ANSIColors`
kept public — both have a demonstrated downstream consumer (Monad's `MemoryRepository` calls
`VectorMath.cosineSimilarity` directly; `WebSocketConnectionManager` uses `ANSIColors`).
**Deferred to PKV3-014**: the legacy flat `LLMConfiguration` initializer and its 18
write-through proxy properties, per this ticket's own escape hatch ("if scope is too large,
defer to a follow-up") — used by all 4 provider adapters and many tests, too large for this
pass without its own migration plan. `swift build` clean, `swift test` 968/968 (165 suites) at
the time; re-verified at 963/963 (167 suites) after the later Track 1 merge.

## Summary

Remove direct compatibility aliases/accessors and lower implementation-only public visibility for v3.

## Implementation Requirements

- Delete `CompactionThresholds`, `EmptySection`, the legacy flat `LLMConfiguration` initializer/proxies, and `TimelineManager.getTimeline(id:)`.
- Retain canonical replacements: `PromptJournalCompactionThresholds`, `EmptyPrompt`, provider-scoped configuration, `timeline(id:)`, and `touchTimeline(id:)`.
- Audit Monad, Shuttle, Yakamoz, docs, examples, and tests; migrate every use.
- Lower `StreamingParser`, `VectorMath`, and terminal-color formatting visibility after proving no external use.
- Exclude ToolOutputParser; PKHYG-005 owns its behavior change.

## Acceptance Criteria

- [ ] No removed compatibility symbol remains in package or consumer source.
- [ ] Canonical replacements preserve intended behavior.
- [ ] Implementation-only types are no longer public without a demonstrated consumer.
- [ ] Migration guide documents every source-breaking replacement.

