# PKV3-015 — Restore dynamic provider-client swapping without a global registry

**Priority:** P1
**Type:** Breaking API / composition follow-up
**Depends on:** PKV3-001
**Blocks:** PKV3-006
**Status:** Done

## Summary

PKV3-001 deleted `ExternalLLMProviderRegistry`/`ProviderFactoryRequest` and the process-global
provider `register()` construction paths — correctly, per its own acceptance criteria ("no
public provider registry/factory-request API remains"). But it left `LLMService` with no
injectable replacement for building a provider client from an `LLMConfiguration` at
runtime, which breaks any host that lets users change LLM configuration live (e.g. via an API
endpoint) and expects the running service to swap provider clients in place.

Found 2026-07-13 while auditing Monad against the `3.0.0-beta.2` prerelease tag for PKV3-006.

## Current Problem

`Sources/PositronicKit/Services/LLM/LLMService+Config.swift`:

```swift
func updateClient(with config: LLMConfiguration) {
    Logger.module(named: "llm").debug("Updating clients for provider: \(config.activeProvider.rawValue)")
    let clients = Self.makeClients(with: config)
    setClients(main: clients.main, utility: clients.utility, fast: clients.fast)
}

/// Static version of client creation for use in init
static func makeClients(with config: LLMConfiguration) -> (
    main: (any LLMClientProtocol)?, utility: (any LLMClientProtocol)?,
    fast: (any LLMClientProtocol)?
) {
    return (main: nil, utility: nil, fast: nil)
}
```

`makeClients(with:)` is a hardcoded stub always returning `nil` clients — a dead no-op left
over from removing the registry lookup it used to perform. `updateClient(with:)` is called from
`loadConfiguration()`, `restoreFromBackup()`, and `updateConfiguration(_:)` — i.e. every path
that reacts to a configuration change after `LLMService` is already constructed. There is no
way for a host to plug in provider-client construction for those paths; only the one-shot
`LLMService.init(configuration:embeddingService:)` and `init(storage:client:utilityClient:fastClient:)`
take clients directly, and neither is re-invoked on a later config change.

Monad's `ConfigurationAPIController` → `LLMService.updateConfiguration(_:)` flow (a user changes
provider/API key via a REST endpoint, the running server should start using the new provider)
depends on exactly this now-dead path. `Sources/MonadServer/LLMProviderBootstrap.swift` still
calls the deleted `PKXProvider.register()` methods and does not compile.

## Implementation Requirements

Pick one direction (recommend the first — it's the smaller, more contained change and
preserves existing host-facing behavior):

1. **Injectable client-factory hook.** Add an optional `clientFactory: (@Sendable (LLMConfiguration) -> (main: (any LLMClientProtocol)?, utility: (any LLMClientProtocol)?, fast: (any LLMClientProtocol)?))?` parameter to the `LLMService.init(storage:...)` initializers, stored and used by `updateClient(with:)` in place of the dead `Self.makeClients(with:)` stub (falls back to `(nil, nil, nil)` if no factory is supplied, matching current behavior for callers that don't need dynamic swapping). Document that hosts compose their factory from each provider's `PKXProvider.makeClient(configuration:)`, keyed on `config.activeProvider` — no process-global state, the closure is owned by whoever constructs `LLMService`.
2. **Host-owned reconstruction.** Leave `LLMService` as-is; instead give hosts a documented pattern (and, if useful, a facade-level convenience) for replacing the whole `LLMService`/`PositronicKit` instance a `TimelineManager`/`ChatEngine` etc. hold when configuration changes, rather than mutating clients in place. This likely touches more of the facade's construction story than option 1.

Whichever direction: migrate Monad's `LLMProviderBootstrap.swift` and `ConfigurationAPIController`
(and whatever wires them into `MonadServerFactory`) to the new pattern, and delete
`LLMProviderBootstrap` if it's no longer needed.

## Acceptance Criteria

- [x] A host can change `LLMConfiguration` after `LLMService` is constructed and have the next
      call use a freshly-built client for the new `activeProvider`, without process-global state.
- [x] `Self.makClients(with:)`'s dead stub is either removed or actually used.
- [x] Monad's `LLMProviderBootstrap.swift` compiles against the change (or is deleted, with its
      caller updated) and its `ConfigurationAPIController` config-update flow still works.
- [x] `make verify` passes; Monad gate passes via the documented local-path override (or against
      the same prerelease tag PKV3-006 is testing with).
