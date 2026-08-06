# PKFAC-003 — Move provider-specific convenience inits out of core into provider targets

**Priority:** P2
**Type:** Public API / target boundaries
**Depends on:** PKFAC-002
**Blocks:** —
**Triage:** wontfix
**Status:** Done — already implemented ahead of this ticket. Confirmed 2026-07-09: `PositronicKit(openAIKey:)`
/ `anthropicKey:` / `ollamaModel:` / `foundationModelsTools:` all live as `public extension PositronicKit`
in `PKOpenAIProvider` / `PKAnthropicProvider` / `PKOllamaProvider` / `PKFoundationModelsProvider`
respectively, delegating to the generic `init(llmService:)`. `grep -rl "PKOpenAI\|PKAnthropic\|PKOllama\|PKFoundationModels" Sources/PositronicKit` returns zero matches — core target references no
concrete provider. No further action needed; keeping this file as a record.

Design: [`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md) §4.

### Summary

The core `PositronicKit` target currently defines provider-specific convenience initializers
(`PositronicKit(openAIKey:)`, `PositronicKit(anthropicKey:)`, `PositronicKit(ollamaModel:)`,
`PositronicKit(foundationModelsTools:)` — see their use in `PositronicKitUsageExamples.swift:30-79`).
Move each into its owning provider target as an `extension PositronicKit`, so core stays
provider-agnostic and importing a provider is what lights up its convenience init.

### Current problem

Provider conveniences in core violate the standing architecture rule that concrete provider adapters stay
out of the core runtime target (CLAUDE.md, `PositronicKit` architecture notes). They also force core to
reference provider registration helpers.

### Implementation Requirements

- [ ] `PositronicKit(openAIKey:)` → `extension PositronicKit` in **PKOpenAIProvider**.
- [ ] `PositronicKit(anthropicKey:)` → **PKAnthropicProvider**.
- [ ] `PositronicKit(ollamaModel:)` → **PKOllamaProvider**.
- [ ] `PositronicKit(foundationModelsTools:)` → **PKFoundationModelsProvider**.
- [ ] Each extension builds the appropriate `LLMServiceProtocol` (+ provider registration) and delegates to
      the generic `init(llmService:)` / `init(configuration:)` from PKFAC-002.
- [ ] Update `PositronicKitExamples` imports so the provider example factories still compile (they already
      import the provider targets).
- [ ] Downstream: grep Monad/Shuttle/Yakamoz for these initializers; any consumer using e.g.
      `PositronicKit(openAIKey:)` must now `import PKOpenAIProvider`.

### Acceptance Criteria

- [ ] Core `PositronicKit` target no longer references any concrete provider; provider conveniences live in
      their targets.
- [ ] `import PKOpenAIProvider` (etc.) is required and sufficient to call the matching convenience init.
- [ ] All three consumers compile against the new arrangement (local-path override until a tag is cut).
- [ ] `make verify` + `make verify-products` green.
