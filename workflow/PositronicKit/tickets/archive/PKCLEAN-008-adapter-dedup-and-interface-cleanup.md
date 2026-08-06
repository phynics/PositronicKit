# PKCLEAN-008 — Deduplicate structured-output adapters; inline `MessageParser`; clean `HealthCheckable` dual methods

**Priority:** P3
**Type:** Refactor (redundancy cleanup)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `f0d32e2`, merged `01443cc`) — items 1 & 2 completed: shared
`PKShared.NativeJSONSchemaStructuredOutputAdapter` replaces the byte-identical
`OpenAIStructuredOutputAdapter`/`OpenRouterStructuredOutputAdapter` pair; `MessageParser`'s two
methods inlined into `Message.swift`, type deleted. Item 3 (`HealthCheckable`) hit its own stop
condition: the ticket's "zero conformers" claim was stale — `Monad/Sources/MonadServer/Services/
Database/DatabaseManager.swift` conforms to `PositronicKit.HealthCheckable` and is wired to a real
HTTP endpoint (`StatusAPIController`), so nothing was removed there; spun off as PKCLEAN-014 with
the corrected downstream context. Downstream grep clean for the removed adapter/`MessageParser`
symbols. `swift test` green (926 tests / 159 suites). `make verify-products` green. CHANGELOG updated.

### Summary

Three redundancy findings:

1. `Sources/PKOpenRouterProvider/OpenRouterStructuredOutputAdapter.swift` is logic-identical
   to `Sources/PKOpenAIProvider/OpenAIStructuredOutputAdapter.swift` (its own comment says
   "OpenRouter mirrors OpenAI's response-format support"). Extract a shared
   implementation (e.g. a `NativeJSONSchemaStructuredOutputAdapter` in `PKShared`, since
   the adapter protocol already lives there) and have both targets register it/thin
   wrappers.
2. `Sources/PKShared/SharedTypes/MessageParser.swift` is only called through the
   pass-through wrappers `Message.parseResponse`/`Message.displayContent`
   (`Message.swift:128–140`). Inline the two methods into `Message.swift` and delete the
   public type (downstream grep first).
3. `Sources/PositronicKit/Services/HealthCheckable.swift` exposes both
   `getHealthStatus()` (cached) and `checkHealth()` (live probe) with identical
   signatures; `UnconfiguredLLMService` implements them identically (dead duplication)
   and only `checkHealth()` is used by consumers. **Update (2026-07-09):** re-checked via
   the code graph — `HealthCheckable` has **zero conformers and zero callers** anywhere
   in the package outside `LLMService`/`LLMServiceProtocol` docs and
   `MockLLMService`/`MockPersistenceService` test doubles; nothing in the runtime
   actually surfaces a health status through it. This reads as leftover scaffolding for
   an HTTP health-endpoint model that belongs downstream (Monad/Shuttle), not core
   orchestration. Prefer **deleting the protocol entirely** over collapsing its two
   methods — confirm via downstream grep (Monad/Shuttle/Yakamoz) that nothing conforms
   to it before removing.

### Acceptance Criteria

- [ ] One shared JSON-schema structured-output implementation; no copy-paste pair.
- [ ] `MessageParser` type gone; behavior preserved via `Message` methods with tests intact.
- [ ] `HealthCheckable` removed entirely (preferred) or, if a downstream conformer is
      found, its contract clarified with no duplicated implementations.
- [ ] Downstream grep clean for removed/renamed symbols (Monad, Shuttle, Yakamoz).
- [ ] `make verify` + `make verify-products` green; CHANGELOG updated.
