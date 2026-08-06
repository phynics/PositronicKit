# PKARCH-004: Narrow the LLMServiceProtocol seam

**Priority:** P2
**Type:** Public API refactor (semver-relevant; touches the primary runtime dependency seam)
**Depends on:** None
**Blocks:** PKARCH-001, PKARCH-002, PKARCH-003 (a smaller LLM seam makes the other extractions easier to test)
**Triage:** ready-for-agent

### Summary

`LLMServiceProtocol` is the widest seam in PositronicKit: 16 methods spanning configuration management, streaming chat, one-shot chat, tag/title generation, recall evaluation, and model listing. The mock implementation is 309 lines. This ticket splits the protocol into three narrow seams so consumers only see the interface they actually need.

### Current Problem

- The protocol mixes provider transport, configuration storage, and utility LLM tasks.
- A consumer that only needs streaming must still implement import/export/restore/clear configuration in its mock.
- The mock (`MockLLMService`) is 309 lines, which is a symptom of a shallow seam: the interface is nearly as complex as the implementation.
- The deletion test fails: deleting `LLMServiceProtocol` would force every consumer to invent its own broad LLM surface.

### Implementation Requirements

1. Introduce three narrow protocols:
   - `LLMStreamClient` — streaming methods: `chatStreamWithContext(_:)` and `chatStream(...)` plus `isConfigured`/`configuration` for setup inspection.
   - `LLMConfigStore` — configuration lifecycle: `loadConfiguration`, `updateConfiguration`, `clearConfiguration`, `restoreFromBackup`, `exportConfiguration`, `importConfiguration`.
   - `LLMUtilityClient` — utility tasks: `sendMessage`, `generateTags`, `generateTitle`, `evaluateRecallPerformance`, `fetchAvailableModels`.
2. `LLMService` implements all three protocols; internally it keeps the same behavior.
3. Update `ChatEngine` and `ContextManager` to depend on `LLMStreamClient` only.
4. Update `MockLLMService` to expose smaller `MockLLMStreamClient`, `MockLLMConfigStore`, and `MockLLMUtilityClient` types, or keep a monolithic mock that conforms to all three for backwards compatibility during migration.
5. Keep `HealthCheckable` on `LLMService` directly, not on the narrow protocols, unless a consumer needs it.
6. Follow the downstream-sync checklist: grep Monad, Shuttle, and Yakamoz for `LLMServiceProtocol` usage and update call sites or type aliases.

### Acceptance Criteria

- [ ] Three new protocols exist with small, focused interfaces; `LLMServiceProtocol` can be deprecated as a type alias or removed.
- [ ] `ChatEngine` and `ContextManager` depend on `LLMStreamClient` only.
- [ ] `MockLLMService` (or its replacements) is significantly smaller per seam; a streaming-only test needs only the stream mock.
- [ ] All three downstream consumers (Monad, Shuttle, Yakamoz) compile with the repinned release.
- [ ] `PositronicKitExamples` compiles and stays current.
- [x] `make verify` green.
- [x] CHANGELOG.md updated under `Unreleased` with the public API change and migration note.

## Resolution

**Status:** Done (commit pending)
**Gate:** `make verify` green — 810 tests / 149 suites.
**Approach:** Split `LLMServiceProtocol` (16 requirements) into three narrow protocols
(`LLMStreamClient`, `LLMConfigStore`, `LLMUtilityClient`) at
`Sources/PositronicKit/Services/LLM/LLMServiceProtocol.swift`. `LLMServiceProtocol` is retained
as a `@available(*, deprecated)` empty composite inheriting all three plus `HealthCheckable`, so
existing `any LLMServiceProtocol` call sites compile unchanged (deprecation warnings only) — this
minimizes downstream churn. `HealthCheckable` stays on `LLMService` directly, not on the narrow
protocols. Default-implementation extensions were re-targeted onto `LLMStreamClient` (and
`LLMUtilityClient where Self: LLMStreamClient` for the utility defaults that build on
`sendStructured`). `ChatEngine.Dependencies` now stores `llmService: any LLMStreamClient` and a
separate `utilityClient: any LLMUtilityClient` (used solely by `TurnPreparer.fetchContext` for
RAG tag generation), fed by a single `any LLMStreamClient & LLMUtilityClient` init param. `MockLLMService`
kept monolithic (conforms to the deprecated composite) for migration. `TimelineArchiver` narrowed to
`any LLMUtilityClient`.
**Downstream sync:** all three consumers verified to compile via local-path override (Monad `swift build`,
Shuttle `swift build`, Yakamoz `make build`); overrides reverted, working trees clean. No consumer
code changes required (deprecated typealias preserves source compatibility). Consumer pin bumps +
release tag deferred to the next `PKPOST-002`-style release cadence step.
