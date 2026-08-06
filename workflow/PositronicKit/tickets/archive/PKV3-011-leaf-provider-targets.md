# PKV3-011 — Make provider adapters leaf targets

**Priority:** P1
**Type:** Module architecture
**Depends on:** PKV3-001, PKV3-009
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done (2026-07-13, PositronicKit `54349bc`, merged to `main` via `347e554`)

**Resolution:** `LanguageModel` and narrow capability protocols relocated to `PKShared`.
Confirmed zero `import PositronicKit` remaining across `PKOpenAIProvider`,
`PKOpenRouterProvider`, `PKOllamaProvider`, `PKAnthropicProvider`, and
`PKFoundationModelsProvider` — each depends only on `PKShared`/`PKUtilities` plus its vendor
SDK. PositronicKit-side provider-convenience extensions removed; hosts construct/inject
concrete clients directly. Provider transport stays internal; adapter behavior preserved
(provider test suites migrated alongside, all green). Landed together with PKV3-001/008/009
as PKV3 Track 1; `swift build`/`swift test` clean post-merge (963/963, 167 suites).

## Summary

Move LanguageModel contracts to PKShared and make provider targets depend only on PKShared/PKUtilities plus their vendor SDKs.

## Implementation Requirements

- Relocate LanguageModel and narrow capabilities to PKShared.
- Remove PositronicKit dependencies from provider target manifests and imports.
- Remove PositronicKit provider-convenience extensions; hosts construct/inject concrete clients directly.
- Keep provider transport implementation internal and preserve adapter behavior.

## Acceptance Criteria

- [ ] Every provider target compiles without importing PositronicKit.
- [ ] Concrete clients implement LanguageModel directly.
- [ ] Provider tests run without the core runtime target except where integration is explicitly tested elsewhere.
- [ ] No convenience/global provider construction path remains.

