# PKRR design decisions — 2026-07-28

Decisions for the three `needs-info` tickets from the PositronicKit remediation
review (PKRR-004, PKRR-005, PKRR-017). Each decision was grounded against the
pinned revision `90646771bd113ae5ffa63816a18153f5fcf9dc9c` and the downstream
consumer audit (Monad, Shuttle, Yakamoz). These decisions unblock implementation
and flip the three tickets to `ready-for-agent`.

## PKRR-004 — Capability-aware tool timeout

**Decision: capability flag + uncertain result.**

Add a `ToolSideEffects` enum to the public `Tool` protocol:

```swift
public enum ToolSideEffects: Sendable, Equatable {
    /// No external state is mutated; safe to abandon after timeout.
    case none
    /// In-process state may be mutated (files, memory, in-process records).
    case mutating
    /// External processes or remote services may be mutated; termination
    /// requires an out-of-band kill path the runtime does not own.
    case externalProcess
}

public protocol Tool: Sendable, PromptFormattable {
    // ... existing requirements ...
    /// The side-effect class of this tool, used by the timeout enforcer to
    /// decide whether abandonment is safe. Defaults to `.mutating` — the
    /// conservative assumption for tools that do not declare themselves
    /// side-effect-free.
    var sideEffects: ToolSideEffects { get }
}

public extension Tool {
    var sideEffects: ToolSideEffects { .mutating }
}
```

`ToolTimeoutEnforcer` behavior changes:

- `sideEffects == .none`: current fast-abandon behavior is preserved. The tool
  task is cancelled best-effort and the enforcer returns immediately with a
  clean timeout error. This is the only case where the runtime claims the
  operation stopped.
- `sideEffects == .mutating` or `.externalProcess`: the enforcer cancels
  best-effort but returns a **distinct terminal state**
  (`timedOutButMayStillBeRunning`) instead of a clean timeout. The caller
  (model/UI/operator) is informed that the tool may still be executing and
  retrying may duplicate side effects. The enforcer does NOT block waiting for
  the uncooperative tool — the `timedOutButMayStillBeRunning` result is
  returned promptly, same as today; only the *reported* status changes.

No idempotency keys, no kill hook, no `ToolTerminatable` protocol in this
ticket. Those are explicitly deferred — the capability flag + honest status is
the minimum viable correctness improvement. A future ticket can add a kill
hook for `.externalProcess` tools if downstream needs it.

**Why not the full suite:** the `Tool` protocol is public with conformers in
every consumer (Monad, Shuttle, Yakamoz, LandGo). Adding a default-valued
property is additive (existing conformers get `.mutating` without code
changes). An execution-id/idempotency-key envelope or a new optional protocol
would change every `execute(...)` call site and every tool conformer — too
much surface for the correctness gain this ticket targets.

**Downstream impact:** additive — existing tool conformers inherit the
`.mutating` default without code changes. Tools that are genuinely
side-effect-free (read-only tools: `cat`, `ls`, `find`, `grep`,
`search_files`) should override to `.none` to keep the clean-timeout path.
Yakamoz's `ReadOnlyToolApproval` allowlist (`cat`/`ls`/`find`/`search_files`/
`grep`) is a good starting point for identifying `.none` candidates across
consumers.

**Acceptance criteria:** as written in PKRR-004, plus:
- `ToolSideEffects` is a public type on `PKShared` (alongside `Tool`).
- Default is `.mutating`; the protocol extension provides it.
- `ToolTimeoutEnforcer` produces `timedOutButMayStillBeRunning` for
  `.mutating`/`.externalProcess` and a clean timeout for `.none`.
- The `timedOutButMayStillBeRunning` state is a typed `ToolResult`/
  `ToolError` case, not a string.

---

## PKRR-005 — `openTimeline` create-vs-open contract

**Decision: fail-closed open + explicit create.**

`openTimeline(_:)` becomes open-existing-only. Sending to a missing timeline
ID throws typed `TimelineError.timelineNotFound` **before any message is
persisted**. `createTimeline(...)` is the distinct creation API. The two
contracts are kept separate.

Changes to `TimelineDriver` and the send path:

1. `PositronicKit.openTimeline(_:)` documentation is updated: it opens an
   **existing** timeline. A missing ID is an error, not a silent creation.
2. `resolveTurnBriefingBuilder` (`PositronicKit.swift:352-372`): hydration
   failure is no longer swallowed. `TimelineError.timelineNotFound` propagates
   as a typed error to the caller before `saveConversationSteps` runs.
   Store-outage (PKRR-008's `unavailable` vs `notFound` distinction) also
   propagates — neither is swallowed.
3. `ChatEngine+TurnPreparation.swift:44-50`: the user input is no longer
   persisted before timeline existence is established. The preparation order
   changes: hydrate/validate timeline existence first, then persist input.
   This is coordinated with PKRR-006 (idempotent persistence unit-of-work).
4. `createTimeline(title:)` remains the explicit creation path
   (`TimelineManager+Lifecycle.swift:9-44`). No "create on first send"
   auto-creation path is added.

**Why fail-closed:** both downstream consumers that use timelines
programatically (Monad, Yakamoz) already call `createTimeline(...)` before
sending. The "send to any UUID and it magically works" path was never correct
— it produced orphan messages with no Timeline/workspace record. Fail-closed
matches existing consumer behavior and makes the contract honest.

**Downstream impact:**
- **Monad**: already creates timelines explicitly via `POST /api/sessions` →
  `timelineManager.createTimeline(...)`. No change required.
- **Yakamoz**: already creates timelines explicitly. No change required.
- **Shuttle**: creates shard timelines explicitly
  (`ShuttleShardAgentRunner.swift:85-90`). No change required.
- **Tests/examples**: any test that sends to a random UUID without creating
  first will now get a typed `timelineNotFound` error. These tests should be
  updated to call `createTimeline(...)` first, or to expect the typed error.
  This is the correct behavior — the test was relying on the bug.

**Dependency:** PKRR-008 (typed store errors) should land first or alongside,
so `timelineNotFound` is distinguishable from a store outage. If PKRR-008 is
not yet done, the implementation can temporarily propagate any hydration
error as a typed `TimelineError` (the not-found vs unavailable split is
refined by PKRR-008 afterward).

**Acceptance criteria:** as written in PKRR-005, plus:
- Sending to a missing ID throws `TimelineError.timelineNotFound` before
  `saveConversationSteps` runs.
- `openTimeline(_:)` doc comment updated to "opens an existing timeline."
- No auto-creation path is added.
- All existing tests that sent to un-created UUIDs are updated or
  explicitly expect the typed error.

---

## PKRR-017 — Persistence configuration durability profiles

**Decision: keep optional init, add validation + startup warnings.**

The current `PersistenceConfiguration` optional-store initializer is kept
unchanged (backward compatible — zero consumer migration). Add:

1. **Cross-store durability validation**: a `func validateDurability() ->
   DurabilityReport` method on `PersistenceConfiguration` (or a free function
   in `PKShared`) that classifies each store as `.durable` or `.ephemeral`
   and returns a report. The classification uses a `var isDurable: Bool`
   property on each store protocol (default `false`; `InMemory*` stores
   remain `false`; GRDB/SwiftData adapters conform to `true`).

2. **Startup warning**: `PositronicKit.init(configuration:)` calls
   `validateDurability()` during construction. If the report shows mixed
   durability (some `.durable`, some `.ephemeral`), the runtime logs a
   `.warning` with the specific stores that are ephemeral and a note:
   "Mixed durability: the following stores are in-memory and will not
   survive restart: [list]. Data persisted to durable stores may reference
   entities that will be missing after restart."

3. **`.fullyPersistent(stores:)` convenience**: a static factory on
   `PersistenceConfiguration` that requires all 7 stores and asserts none is
   `nil`. This is the explicit "I want full durability" path — Monad and
   Shuttle would use this. The optional-store init remains for mixed/ephemeral
   setups.

No `.ephemeral()`/`.mixed(stores:acknowledging:)` profile enums, no
`DurabilityAcknowledgment` parameter, no referential-integrity validation at
startup. The warning is the guardrail; the convenience is the ergonomic path.

**Why not full profiles:** all three consumers pass (nearly) all stores
already (Monad 7/7 GRDB, Shuttle 7/7 SQLite per shard, Yakamoz 6/7 with
`memoryStore` defaulting to in-memory). Replacing the init with explicit
profiles would force a migration on all three for a problem they don't have.
The validation + warning catches the real risk (Yakamoz's missing
`memoryStore`, or a future host that accidentally omits a store) without
migration cost.

**Downstream impact:**
- **Monad**: no change required (passes all 7). Can optionally adopt
  `.fullyPersistent(stores:)` for explicitness.
- **Shuttle**: no change required (passes all 7). Same optional adoption.
- **Yakamoz**: will see a startup warning about `memoryStore` being
  in-memory while the other 6 stores are SwiftData-backed. This is an
  actionable signal — either add a SwiftData `memoryStore` adapter or
  explicitly accept the in-memory memory store (the warning is logged, not
  fatal). No forced migration.
- **Tests**: `PersistenceConfiguration.inMemory()` and the optional-store
  init continue to work unchanged (all-ephemeral does not trigger the mixed
  warning).

**Acceptance criteria:** as written in PKRR-017, plus:
- `var isDurable: Bool` added to the 7 store protocols (default `false`).
- `InMemory*` stores return `false`; GRDB/SwiftData adapters return `true`.
- `validateDurability()` returns a report classifying each store.
- `PositronicKit.init(configuration:)` logs a `.warning` on mixed durability.
- `.fullyPersistent(stores:)` static factory requires all 7, asserts none
  is `nil`.
- No existing consumer's `PersistenceConfiguration` construction breaks.
- The warning message names the specific ephemeral stores.

---

## Consumer audit summary (recorded for all three decisions)

| Consumer | Persistence (today) | PKRR-004 impact | PKRR-005 impact | PKRR-017 impact |
|----------|---------------------|-----------------|-----------------|-----------------|
| Monad | 7/7 GRDB stores | Additive (tools inherit `.mutating` default) | No change (already creates explicitly) | No change (can adopt `.fullyPersistent`) |
| Shuttle | 7/7 SQLite per shard | Additive | No change (already creates explicitly) | No change (can adopt `.fullyPersistent`) |
| Yakamoz | 6/7 SwiftData (`memoryStore` in-memory) | Additive; read-only tools should declare `.none` | No change (already creates explicitly) | Startup warning about `memoryStore` — actionable, not fatal |
| LandGo | PositronicKit prerelease pin | Additive | N/A (deck analysis, not chat timelines) | N/A |
