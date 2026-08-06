---
Priority: P1
Type: Configuration / durability
Depends on: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Public API
Effort: M
Tranche: B (persistence recoverable/idempotent)
Review: PKR-017
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Design spec: workflow/PositronicKit/specs/2026-07-28-pkrr-004-005-017-design-decisions.md
Decision: keep optional init, add validation + startup warnings (2026-07-28)
Resolution: Implemented 2026-07-28. PositronicKit `3f56885` (merge `9bad823`). Added
DurabilityAware protocol (isDurable, default false) as parent for all 7 store protocols.
DurabilityReport with validateDurability() on PersistenceConfiguration. PositronicKit.init
logs .warning on mixed durability naming specific ephemeral stores. .fullyPersistent(stores:)
static factory requires all 7. Additive/backward-compatible. 19 durability tests.
1434 tests in 215 suites pass on merged main.
---

# PKRR-017 — Partially persistent configurations silently mix durable and in-memory state

## Summary
Every omitted persistence store in `PositronicKit+Configuration` silently defaults
to an in-memory implementation, and partial persistence is encouraged. A production
host can persist messages while losing timelines, workspaces, agents, or tool state
on restart.

## Current problem
- `Sources/PositronicKit/PositronicKit+Configuration.swift:62-95` — every omitted
  persistence store silently defaults to an in-memory implementation, and partial
  persistence is encouraged.

## Impact
A production host can persist messages while losing timelines, workspaces, agents,
or tool state on restart. Data becomes unreachable or semantically inconsistent.

## Recommended change
Per the design decision (2026-07-28): **keep optional init, add validation + startup
warnings**.

The current `PersistenceConfiguration` optional-store initializer is kept unchanged
(backward compatible — zero consumer migration). Add:

1. `var isDurable: Bool` on each of the 7 store protocols (default `false`;
   `InMemory*` stores remain `false`; GRDB/SwiftData adapters conform to `true`).
2. `func validateDurability() -> DurabilityReport` on `PersistenceConfiguration`
   (or a free function in `PKShared`) that classifies each store as
   `.durable`/`.ephemeral`.
3. `PositronicKit.init(configuration:)` calls `validateDurability()` during
   construction; mixed durability (some durable, some ephemeral) logs a `.warning`
   naming the specific ephemeral stores and the referential-integrity risk.
4. `.fullyPersistent(stores:)` static factory requiring all 7 stores, asserting
   none is `nil` — the explicit "I want full durability" path.

No `.ephemeral()`/`.mixed(stores:acknowledging:)` profile enums, no
`DurabilityAcknowledgment` parameter, no referential-integrity validation at
startup. The warning is the guardrail; the convenience is the ergonomic path.

## Acceptance criteria
- [x] `var isDurable: Bool` added to the 7 store protocols (default `false`).
- [x] `InMemory*` stores return `false`; GRDB/SwiftData adapters return `true`.
- [x] `validateDurability()` returns a report classifying each store.
- [x] `PositronicKit.init(configuration:)` logs a `.warning` on mixed durability.
- [x] `.fullyPersistent(stores:)` static factory requires all 7, asserts none is
  `nil`.
- [x] No existing consumer's `PersistenceConfiguration` construction breaks.
- [x] The warning message names the specific ephemeral stores.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit); add a durability-profile suite. Public API change —
audit `Monad`/`Shuttle`/`Yakamoz` `Configuration` construction and follow the
downstream-sync checklist.
