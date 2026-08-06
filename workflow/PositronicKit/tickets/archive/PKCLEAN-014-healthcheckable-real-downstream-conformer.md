# PKCLEAN-014 — Reconcile `HealthCheckable`'s dual methods now that a real downstream conformer exists

**Priority:** P3
**Type:** Refactor (redundancy cleanup)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, PositronicKit commit `1752b75`)

**Resolution:** Collapsed `HealthCheckable` to `checkHealth()` + `getHealthDetails()`, dropping the
unused `getHealthStatus()` requirement. Note vs. the triage line: `getHealthDetails()` is **kept** —
`StatusAPIController.swift:45,48` actively calls it (dbDetails/aiDetails); only `getHealthStatus()` was
dead through the protocol. Removed the duplicated `getHealthStatus()` impls from `LLMService`,
`UnconfiguredLLMService`, `MockLLMService`, `MockPersistenceService`; updated `SystemStatusTests` and
`LLMServiceTests`. Downstream conformers with a leftover `getHealthStatus()` method still compile
(extra methods are allowed), so no downstream break; a Monad-side removal of its now-orphaned
`DatabaseManager.getHealthStatus()` is a separate optional cleanup. PK build clean; health tests pass.
CHANGELOG updated.

> **Triage resolved 2026-07-10:** the cross-boundary question is answered by the code, no design
> call needed. `StatusAPIController.swift:44,47` calls only `checkHealth()`; `getHealthStatus()` has
> **zero** callers in Monad (defined on `DatabaseManager` but never invoked). Direction: collapse
> `HealthCheckable` to the single live-probe method `checkHealth()`, drop `getHealthStatus()`, and
> update `UnconfiguredLLMService` + mocks + the `StatusAPIController` test double to match. Confirm
> the Shuttle/Yakamoz grep stays clean (neither conforms today).

### Summary

Split off from PKCLEAN-008 item 3. That ticket's premise ("`HealthCheckable` has zero conformers
and zero callers anywhere... outside test doubles") was stale: re-checked during PKCLEAN-008 and
found `Monad/Sources/MonadServer/Services/Database/DatabaseManager.swift` conforms to
`PositronicKit.HealthCheckable`, wired through `Monad/Sources/MonadServer/Controllers/
StatusAPIController.swift` to a real HTTP status endpoint. So `HealthCheckable` is not dead
scaffolding — it backs a real Monad feature.

### Current Problem

`Sources/PositronicKit/Services/HealthCheckable.swift` still exposes both `getHealthStatus()`
(cached) and `checkHealth()` (live probe) with identical signatures; `UnconfiguredLLMService`
implements them identically (dead duplication within PositronicKit itself), while Monad's real
conformer (`DatabaseManager`) presumably only needs one of the two shapes for its status endpoint.

### Implementation Requirements

1. Read `Monad/Sources/MonadServer/Services/Database/DatabaseManager.swift`'s conformance and
   `StatusAPIController.swift`'s usage to determine which of `getHealthStatus()`/`checkHealth()`
   Monad actually calls, and whether both are load-bearing there.
2. Decide (human input likely needed here, since this crosses the PositronicKit/Monad boundary):
   collapse `HealthCheckable` to one method if Monad only needs one, or clarify/document why both
   are needed if Monad genuinely uses both semantics (cached vs. live-probe).
3. Update `UnconfiguredLLMService` and any mocks (`MockLLMService`/`MockPersistenceService`) to
   match the resolved contract.
4. Re-run the downstream grep across Monad/Shuttle/Yakamoz before closing.

### Acceptance Criteria

- [ ] `HealthCheckable`'s contract matches what Monad's `DatabaseManager`/`StatusAPIController`
      actually need — no unused method shape.
- [ ] No duplicated identical implementations remain in-package.
- [ ] Downstream grep re-confirmed (Monad, Shuttle, Yakamoz).
- [ ] `make verify` green; CHANGELOG updated if the public contract changes.
