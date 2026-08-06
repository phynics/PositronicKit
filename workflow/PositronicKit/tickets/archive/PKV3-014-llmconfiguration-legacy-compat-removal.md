# PKV3-014 — Remove legacy flat `LLMConfiguration` initializer and proxy properties

**Priority:** P2
**Type:** Breaking API cleanup
**Depends on:** —
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done (2026-07-13, PositronicKit `07c1dbf`; DocC fix `fc9ce0e`)

**Resolution:** Deleted the legacy flat `LLMConfiguration` initializer and its 18 write-through
proxy properties. Added `LLMConfiguration.activeProviderConfiguration: ProviderConfiguration`
as the canonical read-only replacement (`providers[activeProvider]`, falling back to
`ProviderConfiguration.defaultFor(activeProvider)`). Migrated every in-package call site: all 4
provider adapters' `makeClient(configuration:)`, `LLMService`/`LLMService+Config`/
`LLMService+Stream`, `LLMServiceProtocol+StructuredOutput`, `LLMStreamingStage`,
`ChatEngine+TurnPreparation`, `PositronicKitExamples`. Added a test-only
`LLMConfiguration.fixture(...)` to `PKTestSupport/TestFixtures.swift` (mirrors the old flat-init
ergonomics via the canonical constructor) and migrated ~20 test files onto it or onto
`activeProviderConfiguration` directly. One real behavior difference surfaced and was fixed in
`ConfigurationTests`: the old flat init always defaulted `timeoutInterval` to 60s regardless of
provider; `activeProviderConfiguration` correctly uses each provider's own default (Ollama:
120s, for slower local models).

**Downstream audit** (per acceptance criteria): grepped Monad, Shuttle, Yakamoz.
- **Monad**: `ConfigCommand.applyConfigValue(...)` wrote through the deleted proxies directly —
  migrated to `config.providers[config.activeProvider]?.<field>` (Monad commit, source-level
  only — local-path override build currently blocked by an unrelated pre-existing issue,
  `PKTestSupport` dropped as a public product ahead of Monad's pin; verified against Monad's
  current released pin instead, `swift build`/`swift test --filter Configuration` green).
  `ConfigurationStorage.swift`'s apparent proxy usage was a false positive — the touched fields
  belong to a private on-disk migration DTO (`LegacyLLMConfigurationV1`), unrelated to
  PositronicKit's type.
- **Yakamoz**: `ProviderSettings.configuration(apiKey:)` (both `Snapshot` and the live-settings
  wrapper) used the flat init — migrated to build a single-provider `ProviderConfiguration` and
  pass it through the canonical constructor; stale doc comment fixed. `make build` succeeds
  (Xcode); no dedicated test file exists for this function to run directly.
- **Shuttle**: no `LLMConfiguration` usage at all — clean.

Also fixed, as a release-gate blocker discovered along the way: `Sources/PKShared/Tools/Tool.swift`'s
`Tool.identity` doc comment had unresolvable DocC symbol links (`` ``ToolReference.custom`` ``,
`` ``known(id:)`` ``), breaking `validate-docs`/`make verify` since PKV3-012. Switched to
plain-text mentions. **`make verify` is now fully green** (963 tests / 167 suites), which also
satisfies part of PKV3-006's own PositronicKit-gate requirement.

## Summary

Split off from [PKV3-007](archive/PKV3-007-remove-compatibility-surface.md) (2026-07-13):
that ticket's own text authorized deferring this piece if scope was too large, and it is —
the legacy flat `LLMConfiguration` initializer and its 18 write-through proxy properties are
used by all 4 provider adapters (`PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider`,
`PKAnthropicProvider`) and many tests, so it needs its own migration plan rather than folding
into a broader compatibility-surface pass.

## Current Problem

`Sources/PKShared/SharedTypes/LLMConfiguration.swift` carries a `providers`/`activeProvider`
dictionary-keyed design (the canonical shape) alongside a legacy flat initializer:

```swift
/// Convenience init for legacy support (flat structure)
public init(
    endpoint: String = "https://api.openai.com",
    modelName: String = "gpt-4o",
    ...
) { ... }
```

and 18 computed properties (`endpoint`, `apiKey`, `modelName`, `utilityModel`, `fastModel`,
`toolFormat`, `timeoutInterval`, `maxRetries`, `temperature`, `maxTokens`, `topP`,
`frequencyPenalty`, `presencePenalty`, `seed`, `applicationURL`, `applicationTitle`,
`generationParameters`, `provider`) that are write-through proxies onto
`providers[activeProvider]`, documented in the file as existing "for source-compatibility with
call sites written before `providers`/`activeProvider` was introduced."

## Implementation Requirements

- Grep every call site of the flat initializer and each proxy property across
  `PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider`, `PKAnthropicProvider`,
  `PositronicKit`, `PositronicKitExamples`, and their test targets; migrate each to construct
  `LLMConfiguration(activeProvider:providers:...)` directly and read/write
  `providers[activeProvider]` (or a `ProviderConfiguration` local) instead of the proxy.
- Delete the flat initializer and all 18 proxy properties once no call site remains.
- Audit Monad, Shuttle, Yakamoz for the same patterns (provider-scoped configuration is the
  canonical replacement per PKV3-007's acceptance criteria); migrate every use.
- Update `PKSharedTests/LLMConfigurationModelsTests.swift` and any other test relying on the
  flat shape.
- CHANGELOG entry (public API removal), building on the "Deferred to a follow-up" note already
  in `CHANGELOG.md`'s PKV3-007 entry.

## Acceptance Criteria

- [ ] No call site of the legacy flat `LLMConfiguration` initializer or its 18 proxy properties
      remains in package or consumer source.
- [ ] `LLMConfiguration` construction/access goes exclusively through `providers`/`activeProvider`
      (or a documented ergonomic replacement).
- [ ] `make verify` passes; downstream gates run through the documented local-path override.
