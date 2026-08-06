# PKV3-005 — Name turn briefing and prompt journal roles

**Priority:** P2
**Type:** Breaking API / terminology
**Depends on:** —
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done

## Summary

Replace overloaded context/history/inspector terminology with TurnBriefing, TurnBriefingBuilder, TimelinePromptJournals, and PromptObserver while preserving prompt materialization behavior.

## Current Problem

- `ContextManager` retrieves, ranks, and packages selected material, not generic execution context.
- `TimelinePromptHistoryRegistry` owns cache-aware prompt journals, not literal transcript history.
- `PromptInspecting` receives notifications rather than actively interrogating prompts.

## Implementation Requirements

- Introduce TurnBriefing as the selected memory/workspace material for one turn.
- Rename ContextManager to TurnBriefingBuilder and migrate its pipeline.
- Rename TimelinePromptHistoryRegistry to internal TimelinePromptJournals unless a real public consumer requires access.
- Keep PromptJournal and its cache/compaction semantics.
- Rename PromptInspecting/PromptInspector to PromptObserving/PromptObserver; migrate Yakamoz inspector integration.

## Acceptance Criteria

- [ ] TurnBriefing output is used by prompt assembly and retains current ranking behavior.
- [ ] Prompt journal compaction/cache semantics remain unchanged.
- [ ] Prompt observers receive assembled prompts with no old inspector/history names.
- [ ] Package and downstream prompt-inspection tests pass.

