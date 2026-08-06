# PKAPI-007 — Provider/LLM-service parameter ergonomics: unlabeled Factory tuple, ambiguous booleans, silent write-through setters

**Priority:** P2
**Type:** API design
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `11531cd`, merged into `main`) — `ExternalLLMProviderRegistry.Factory`
now takes a labeled `ProviderFactoryRequest` struct instead of an unlabeled 5-tuple; all 5 provider
targets' `register()` factories updated. `useUtilityModel`/`useFastModel` booleans on `chatStream`
replaced by a single `modelTier: ModelTier` enum (`.primary`/`.utility`/`.fast`), removing the
undocumented dual-boolean precedence; `LLMChatRequest.useFastModel` renamed to `modelTier`.
`LLMConfiguration`'s backwards-compat computed properties documented (not restructured) as
write-through proxies onto `providers[activeProvider]` (option a from the ticket — no prior-incident
evidence found to justify the larger restructure). First diff missed two stale call sites
(`MockLLMService.chatStream`'s old boolean overload, `UnconfiguredLLMServiceTests`) that broke
`swift build`/`swift test` — fixed during review before merge, plus the ticket's own doc-comment
requirement (`make verify`'s `validate-docs` gate caught `chatStream`'s 5 other unnamed params
missing docs after only `modelTier` was documented — fixed in a follow-up commit `fade063`).
`make verify` green (932 tests / 159 suites on `main` after merge). CHANGELOG updated (Breaking).

### Summary

Three confirmed issues across the provider/configuration layer:

1. **`ExternalLLMProviderRegistry.Factory` is 5 unlabeled positional parameters.**
   `Sources/PKShared/SharedTypes/LLMProviderContracts.swift:293-299`:
   ```swift
   public typealias Factory = @Sendable (
       LLMConfiguration, EndpointComponents, TimeInterval, Int, String?
   ) -> (any LLMClientProtocol)?
   ```
   `TimeInterval`, `Int`, and `String?` are unidentifiable at any call site — the actual
   implementations name them `config, components, timeout, retries, model`, but the
   `typealias` itself carries no labels (Swift closure types can't label parameters).
2. **`LLMStreamClient.chatStream` has two undocumented, possibly-conflicting booleans.**
   `Sources/PositronicKit/Services/LLM/LLMServiceProtocol.swift:135-143` (and the
   default-args convenience overload at 189-197) takes `useUtilityModel: Bool` and
   `useFastModel: Bool` with no documentation of their relationship — can both be `true`?
   What wins if so? What does "neither" mean (primary model, presumably, but that's not
   stated)?
3. **`LLMConfiguration` computed properties silently write through to a nested dictionary,
   and `provider` duplicates `activeProvider`.** `Sources/PKShared/SharedTypes/LLMConfiguration.swift`
   — `endpoint`, `apiKey`, `modelName`, `utilityModel`, `fastModel`, `toolFormat`,
   `timeoutInterval`, `maxRetries`, `temperature`, `maxTokens`, `topP`,
   `frequencyPenalty`, `presencePenalty`, `seed`, `applicationURL` (lines 15-90ish) all
   have setters that mutate `providers[activeProvider]`. `config.apiKey = "..."` reads
   like a plain property set but actually reaches into a nested dictionary keyed by
   whatever `activeProvider` currently is — surprising if `activeProvider` changes
   between read and write. Additionally `var provider: LLMProvider` (line ~103) is a
   second name for `activeProvider` with no doc explaining why both exist. Note: the file
   marks this whole section `// MARK: - Computed Properties (Backwards Compatibility)` —
   this may be intentional legacy-compat surface, not an oversight, but it's undocumented
   as such at the property level.

### Implementation Requirements

- [ ] Replace `Factory`'s tuple-of-5 with a labeled struct (e.g.
      `ProviderFactoryRequest { config, components, timeout, retries, model }`) — closure
      type aliases can't carry argument labels, so a struct parameter is the real fix.
      Update all `register(...)` call sites in
      `PKAnthropicProvider`/`PKFoundationModelsProvider`/`PKOllamaProvider`/`PKOpenAIProvider`/`PKOpenRouterProvider`.
- [ ] Replace `useUtilityModel`/`useFastModel` booleans with a `ModelTier` enum
      (`.primary`/`.utility`/`.fast`) on `chatStream`, or if changing the signature is too
      disruptive right now, at minimum document the precedence/mutual-exclusivity
      contract inline.
- [ ] For `LLMConfiguration`: either (a) document explicitly on each computed property
      that it's a write-through to `providers[activeProvider]` and that this is
      intentional backwards-compat surface, or (b) convert to read-only computed
      properties plus explicit `mutating func setApiKey(_:)`-style methods if the silent
      write-through has actually caused bugs (check git history/tickets for prior
      incidents before doing the larger rework). Document why `provider` duplicates
      `activeProvider`, or deprecate one in favor of the other.

### Acceptance Criteria

- [ ] `Factory` callers use a labeled request type; no unlabeled 5-tuple in the public
      contract.
- [ ] `chatStream`'s model-tier selection is either an enum or explicitly documented.
- [ ] `LLMConfiguration`'s write-through behavior is documented (minimum) or restructured
      (if warranted) — decision recorded either way.
- [ ] Downstream grep across Monad/Shuttle/Yakamoz for provider `register(...)` calls and
      `LLMConfiguration` property mutation.
- [ ] `make verify` + `make verify-products` green; CHANGELOG updated if signatures change.
