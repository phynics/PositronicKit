# PKLOG-004 — Structured log metadata and PKError consistency across the turn loop

**Priority:** P3
**Type:** Observability / consistency
**Depends on:** PKLOG-001, PKLOG-002
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `2321ac5`) — added public `PKShared.LogKeys` namespace
(`timelineID`/`sendID`/`turnIndex`/`toolName`/`provider`/`stage`/`errorCode`); renamed the legacy
`conversationID` metadata key to canonical `timelineID` across the loop audit-trail sites and
applied canonical keys to prompt-assembly, LLM-stream-lifecycle, loop-continuation, and
tool-routing logs. Each loop component (`TurnPreparer`, `TurnLoopController`, `PromptSnapshotBuilder`,
`PartialAssistantPersistence`, `LLMStreamingStage`, `ToolCallExtractionStage`,
`MessagePersistenceStage`) now defaults to a dedicated `Logger.module(named:)` category while still
accepting DI injection. Foreign (non-`PKError`, non-`CancellationError`) provider transport errors
reaching callers are wrapped in internal `LLMStreamError` (domain `llm`, code 1005, original error
preserved as `underlyingError`) at the stream-failure leak points; existing `PKError` errors and
`CancellationError` pass through unchanged. 2 new tests + 1 updated. `make verify` green (926 tests
/ 159 suites).

### Decision (2026-07-08) — canonical metadata vocabulary

Use a `LogKeys`-style namespace of camelCase keys mirroring the existing logger scheme
(`"chat-engine"` / `"tool-router"` / `"llm"` categories). Canonical key set:
`timelineID`, `sendID`, `turnIndex`, `toolName`, `provider`, `stage`, `errorCode`.
Before implementing, grep current `Logger.Metadata` usage (esp. `ToolCallExtractionStage`)
and align to whatever keys already exist rather than introducing synonyms. New loop
components get named categories consistent with the existing scheme. Otherwise implement
per the requirements as written.

Note: PKLOG-004 depends on PKLOG-001/002 and references `TurnLoopController`, which
PKDEEP2-001 folds into `ChatEngine` — apply metadata at whatever the surviving loop
call sites are at implementation time.

### Summary

Structured `Logger.Metadata` is used only in `ToolCallExtractionStage`; `ChatEngine`,
`TurnLoopController`, `LLMStreamingStage`, and pipeline orchestration log via string
interpolation, making downstream correlation (by timeline/send/turn) impossible without
regex. Separately, domain errors conform to `PKError` (`ChatEngineError`, `SidecarError`,
`ContextManagerError`) but provider transport errors pass through unwrapped, without
domain/code annotation. Also, several loop components (`TurnLoopController`,
`PromptSnapshotBuilder`, `PartialAssistantPersistence`, pipeline stages) have no
dedicated logger category.

Marked ready-for-human because the metadata-key vocabulary (e.g. `timelineID`, `sendID`,
`turnIndex`, `toolName`) should be decided once and documented before mechanical
application.

### Implementation Requirements

1. Define a small canonical metadata-key set in one place (doc comment or a
   `LogKeys`-style namespace) and apply it to prompt-assembly events, LLM stream
   lifecycle, loop continuation decisions, and tool routing.
2. Give each loop component a named logger category consistent with the existing
   `"chat-engine"` / `"tool-router"` / `"llm"` scheme.
3. Wrap unannotated provider errors surfaced by the loop in a `PKError`-conforming type
   with a stable `errorCode` (keep original error as the underlying cause per ErrorKit
   conventions).

### Acceptance Criteria

- [ ] Canonical metadata keys documented and used at the listed points.
- [ ] Every loop component logs under a named category.
- [ ] Provider errors reaching callers carry a PKError domain/code.
- [ ] `make verify` green.
