# PKV3-001 — Inject LanguageModel and remove global provider registration

**Priority:** P1
**Type:** Breaking API / composition
**Depends on:** —
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done (2026-07-13, PositronicKit `3a58617`, merged to `main` via `347e554`)

**Resolution:** Public `LanguageModel` protocol added as the composition of stream/config/utility
capabilities; `PositronicKit+Configuration` now takes `languageModel` (public composition
vocabulary renamed from `llmService`). `ExternalLLMProviderRegistry` and `ProviderFactoryRequest`
deleted along with provider `register()` global-registration construction paths (only a stale
doc-comment reference remains in `PositronicKitExamples`, harmless). `ProviderHTTPTransport` is
package-internal (relocated into the new `PKUtilities` target by PKV3-009/011). Landed together
with PKV3-008/009/011 as PKV3 Track 1; `swift build`/`swift test` clean post-merge (963/963,
167 suites).

## Summary

Make one explicitly injected `LanguageModel` the facade composition requirement; remove global provider registration and rename public `llmService` composition vocabulary.

## Current Problem

- `PositronicKit+Configuration.swift` already requires one composition of `LLMStreamClient`, `LLMConfigStore`, and `LLMUtilityClient`, but exposes it through `llmService` terminology.
- `ExternalLLMProviderRegistry` and `ProviderFactoryRequest` use process-global mutable registration to rebuild provider clients.
- Users should select/inject their provider at the host composition root, not configure PositronicKit transport or registry state.

## Implementation Requirements

- Introduce public `LanguageModel` as the composition of stream/config/utility capabilities; keep narrow capability protocols for internal/advanced seams.
- Rename public composition fields/parameters from `llmService` to `languageModel`.
- Delete `ExternalLLMProviderRegistry`, `ProviderFactoryRequest`, and provider `register()` construction paths.
- Keep `ProviderHTTPTransport` package-internal.
- Migrate Monad/Shuttle/Yakamoz dynamic selection into explicit host-owned factories where needed.

## Acceptance Criteria

- [ ] A kit constructed with a fake `LanguageModel` runs a turn with no global registration.
- [ ] No public provider registry/factory-request API remains.
- [ ] Provider convenience initialization uses direct injection or host-owned selection.
- [ ] Package and local-override consumer gates pass.

