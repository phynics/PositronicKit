# PKCLEAN-003 — Retire the deprecated LLMServiceProtocol composite from the facade

**Priority:** P2
**Type:** API migration (public API change)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `29bd5b5`) — facade `llmService` is now
`any LLMStreamClient & LLMConfigStore & LLMUtilityClient` (the three narrow seams; `HealthCheckable`
no longer required by the facade); deleted the deprecated `LLMServiceProtocol` composite.
`LLMService`/`UnconfiguredLLMService`/`MockLLMService` conform to the three narrow protocols
directly. Zero `LLMServiceProtocol` refs in Sources/Tests. PositronicKit-side only — Monad migration
tracked by `MON-PK-2`, Shuttle/Yakamoz gaps noted, release-cut + pin bumps deferred. `swift test`
green (923 tests / 158 suites).

### Decision (2026-07-08) — **(a) Migrate the facade, retire the composite**

Finish what PKARCH-004 started: make the deprecation guidance actionable by moving the
facade off `any LLMServiceProtocol` onto the narrow protocols, then delete the composite.
Follow "Implementation Requirements (direction (a))" below. This is a public API change —
cut the compatible PositronicKit release and bump consumer pins per `docs/Releasing.md`
and the release-line upgrade flow. Run the downstream-sync checklist (grep Monad, Shuttle,
Yakamoz for `LLMServiceProtocol`) before closing.

**Scope for this ticket (2026-07-09):** implement the PositronicKit-side migration only —
facade initializers, `MockLLMService`/`UnconfiguredLLMService` conformances, deleting the
composite. **Downstream call-site migration in Monad is deliberately out of scope here** —
tracked separately as `MON-PK-2` (`workflow/Monad/tickets/`), to be picked up once this
release is cut and Monad's pin bumps. Do not edit Monad in this ticket. (Shuttle/Yakamoz
downstream migration is not tracked yet — file equivalent tickets in their own trees if/when
picked up; note this gap in the ticket resolution rather than silently skipping it.) Since
Monad won't be migrated yet, the actual release-cut + consumer-pin-bump step in
Implementation Requirement 5 should also wait — land the PositronicKit-side change and stop
short of tagging/publishing a release or bumping pins without separate confirmation.

### Summary

`LLMServiceProtocol` is marked `@available(*, deprecated)` (PKARCH-004) but is still the
`PositronicKit` facade's primary `llmService` parameter type in 6 places. The deprecation message
tells callers to "Depend on `LLMStreamClient`, `LLMConfigStore`, or `LLMUtilityClient` directly"
— but the only public entry point requires the deprecated composite, so the guidance is
unactionable from outside. Decide whether to (a) migrate the facade to the narrow protocols and
retire the composite, or (b) un-deprecate it and keep it as the canonical seam.

### Current Problem

- `Sources/PositronicKit/Services/LLM/LLMServiceProtocol.swift:184`:
  ```swift
  @available(*, deprecated, message: "Depend on LLMStreamClient, LLMConfigStore, or LLMUtilityClient directly; LLMService conforms to all three.")
  public protocol LLMServiceProtocol: LLMStreamClient, LLMConfigStore, LLMUtilityClient, HealthCheckable {}
  ```
- The facade uses `any LLMServiceProtocol` as its `llmService` parameter type at
  `Sources/PositronicKit/PositronicKit.swift:30, 80, 128, 214, 434, 463`.
- `MockLLMService` (`Tests/PKTestSupport/MockLLMService.swift:191`), `UnconfiguredLLMService`,
  and `LLMService` all conform to the composite.
- PKARCH-004 (2026-07-06) split the 16-requirement protocol into three narrow protocols and kept
  `LLMServiceProtocol` as a deprecated composite "so downstream `any LLMServiceProtocol` call
  sites compile unchanged (deprecation warnings only)."

The contradiction: the deprecation nudges toward the narrow protocols, but the facade — the
primary public entry point — still demands the composite, so no downstream caller can actually
follow the guidance without bypassing the facade.

### Implementation Requirements (direction (a) — migrate facade)

1. Change the facade's `llmService` parameter from `any LLMServiceProtocol` to
   `any LLMStreamClient` (the streaming seam is the one the facade actually drives). If the
   facade also reads config/utilities, widen to a tuple of the narrow protocols or a small
   `LLMService`-style concrete injection.
2. Update `MockLLMService` / `UnconfiguredLLMService` conformances to the narrow protocols.
3. Grep **all three consumers** (Monad, Shuttle, Yakamoz) for `any LLMServiceProtocol` /
   `LLMServiceProtocol` call sites and migrate them to the narrow protocols (downstream-sync
   checklist — root `CLAUDE.md`).
4. Once no in-repo or downstream caller references the composite, delete
   `LLMServiceProtocol` (line 184) and its `// MARK: - Deprecated composite` section.
5. This is a **public API change** — update `CHANGELOG.md` under `Unreleased` → `Breaking` (or
   `Changed` if the narrow protocols are source-compatible supertypes) and follow
   `docs/Releasing.md` for the tag/pin workflow. Bump the consumer pins per the release-line
   upgrade flow.

### Implementation Requirements (direction (b) — un-deprecate)

1. Remove the `@available(*, deprecated, ...)` from `LLMServiceProtocol.swift:184`.
2. Update the PKARCH-004 changelog note and the deprecation message.
3. Document that the composite is the canonical facade seam, not a migration shim.

### Acceptance Criteria

- [ ] Direction chosen and documented in the ticket resolution.
- [ ] If (a): no `LLMServiceProtocol` references remain in Sources or in Monad/Shuttle/Yakamoz;
      `make verify` green; consumer pins bumped; `CHANGELOG.md` updated.
- [ ] If (b): `@available(*, deprecated)` removed; `make verify` green; `CHANGELOG.md` updated.
- [ ] Downstream-sync checklist run (grep Monad, Shuttle, Yakamoz).
