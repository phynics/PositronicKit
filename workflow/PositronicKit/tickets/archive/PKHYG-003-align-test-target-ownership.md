# PKHYG-003 — Align tests with their owning package targets

**Priority:** P2
**Type:** Test architecture
**Depends on:** PKHYG-001
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done

**Resolution (2026-07-12):** Created 5 provider test targets (`PKOpenAIProviderTests`,
`PKOpenRouterProviderTests`, `PKOllamaProviderTests`, `PKAnthropicProviderTests`,
`PKFoundationModelsProviderTests`). Moved 12 provider-specific suites out of
`PositronicKitTests` into their owning targets. Moved 8 PKShared-owned test files into
`PKSharedTests`. `PositronicKitTests` no longer depends on provider targets or the OpenAI
SDK. Cross-provider suites kept in core. 948 tests / 162 suites green. PositronicKit `1607150`.

## Summary

Move provider-adapter and `PKShared` coverage out of `PositronicKitTests` into module-owned test targets, leaving core tests responsible for runtime and cross-module behavior.

## Current Problem

- `Package.swift` makes `PositronicKitTests` depend on every provider target and the OpenAI SDK.
- Provider tests live below `Tests/PositronicKitTests/Services/LLM/Providers/` and at its root, hiding provider ownership.
- `PKShared` value-type tests, including `Models/Configuration/LLMConfigurationModelsTests.swift` and workspace/model tests, also live in the core target despite `PKSharedTests` existing.

## Implementation Requirements

- Create `PKOpenAIProviderTests`, `PKOpenRouterProviderTests`, `PKOllamaProviderTests`, `PKAnthropicProviderTests`, and `PKFoundationModelsProviderTests` in `Package.swift`.
- Move each provider-specific suite into its provider target; give each target only its provider, `PKShared`, `PKTestSupport` when imported, and direct external products it actually imports.
- Move PKShared-owned tests (`AnyCodable`, generation parameters, agent template, API response metadata, memory, workspace URI/reference/tool definition, and LLM configuration) into `PKSharedTests`, organized by shared domain.
- Keep `ProviderTransportContractTests`, `ProviderHTTPFailureTests`, `ProviderInitializationTests`, and `StreamDecodingConformanceTests` in core unless their import/dependency audit proves single-provider ownership.
- Preserve `PositronicKitExamples` story coverage in `PositronicKitTests` as explicitly justified by the existing manifest comment.

## Acceptance Criteria

- [ ] Every new provider test target executes at least one test independently.
- [ ] `PKSharedTests` contains the moved PKShared contracts/models and passes independently.
- [ ] `PositronicKitTests` no longer owns concrete provider-specific suites or unnecessary SDK dependencies.
- [ ] `swift test` passes with no loss of examples story coverage.

