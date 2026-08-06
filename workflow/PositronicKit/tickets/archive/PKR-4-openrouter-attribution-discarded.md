# PKR-4 — OpenRouter attribution params silently discarded by the public initializer

**Status:** Done — added `applicationURL`/`applicationTitle` to `ProviderConfiguration` (PKShared) with matching passthrough computed properties + legacy-init parameters on `LLMConfiguration`; `PKOpenRouterProvider.register()`'s factory closure now reads `config.providers[.openRouter]?.applicationURL/applicationTitle` and builds a real `OpenRouterClient.Attribution`, which it passes into the client. `PositronicKit.init(openRouterKey:...)` now binds `applicationURL`/`applicationTitle` into the `LLMConfiguration` instead of discarding them (`_`), so the public init sets the real `HTTP-Referer`/`X-Title` headers end-to-end; `nil` still omits the headers rather than sending them empty. Added `openRouterConvenienceInitializationWiresAttribution` and `openRouterConvenienceInitializationOmitsAttributionWhenNil` to `Tests/PositronicKitTests/Stories/Setup/RuntimeSetupStoriesTests.swift` (via a new internal `OpenRouterClient.currentAttribution` test seam, `@testable`-only). `swift build && swift test` green (632 tests, 123 suites, 0 failures). Confirmed zero downstream impact — no consumer (Monad/Shuttle/Yakamoz) references this init or attribution headers.
**Severity:** 🟠 Medium (public API silently no-ops)
**Repos:** PositronicKit (PKOpenRouterProvider)
**Source:** PositronicKit review 2026-07-02

## Problem

`PositronicKit.init(openRouterKey:...)` (`Sources/PKOpenRouterProvider/PKOpenRouterProvider.swift:21-34`,
verified) declares `applicationURL`/`applicationTitle` but binds both to `_` — they are never
turned into an `OpenRouterClient.Attribution` (`OpenRouterClient.swift:293-301`, consumed at
`:483-488` for `HTTP-Referer`/`X-Title`). The registry factory signature
(`LLMService+Config.swift:143-149`) has no attribution slot either, so no public construction
path can ever set these headers; only the `package` init used in tests can.

## Suggested direction

Either thread attribution through the `ExternalLLMProviderRegistry` factory/config (e.g. as
provider-specific options on `LLMConfiguration`), or remove the two dead parameters until a real
path exists — a public parameter that silently does nothing is worse than absence.
