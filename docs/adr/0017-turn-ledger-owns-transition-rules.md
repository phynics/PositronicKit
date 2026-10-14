---
status: accepted
---

# The Turn ledger owns transition rules; the repository commits rows

ADR 0003 makes one `TimelineRuntimeRepository` the transactional owner of Timeline history and
Turn durability. ADR 0007 keeps that cohesion. This ADR moves the **decision rules** for every
Turn transition into a runtime-owned, storage-free module and leaves the repository responsible
for loading a snapshot and committing the returned rows atomically. It amends ADR 0003 and
ADR 0007; it does not supersede either. Issue
[#300](https://github.com/phynics/PositronicKit/issues/300) motivates it.

## Context

`TimelineRuntimeRepository` has ten invariant-bearing transactions: `admitTurn`, `admitRetry`,
`recordTurnMessage`, `beginModelRound`, `recordProviderRequest`, `recordToolIntent`,
`recordToolResult` (two overloads), `completeTurn`, `interruptTurn`, and `releaseQuarantine`. The
rules they enforce — Request-ID idempotency, busy and quarantine rejection, the tool-result
barrier, ordered message membership, first-writer-wins terminal commits, and append-only history —
are stated in prose on the protocol and implemented only in
`InMemoryTimelineRuntimeRepository`. A durable adapter that does not embed that actor has to
reproduce every rule; the 16-scenario conformance suite is the only check that it did.

### Investigation findings

1. **Scenario-to-rule map.** Every conformance scenario resolves to a ledger decision:

   | Conformance scenario | Ledger decision |
   | --- | --- |
   | `admission.input`, `admission.message-free`, `admission.serialization`, `admission.invalid-input`, `admission.authority` | `decideAdmission` |
   | `retry.linkage` | `decideAdmitRetry` |
   | `tool.barrier` | `decideBeginModelRound` |
   | `tool-result.atomicity` | `decideRecordToolResult` |
   | `turn.membership` | `decideAdmission` + `decideRecordTurnMessage` + `decideRecordToolResult` + `decideCompleteTurn` |
   | `history.append-only` | append-only equivalence + `decideRecordTurnMessage` / `decideCompleteTurn` |
   | `history.ordering` | storage ordering (`TimelineMessage.chronological()`), not a ledger rule |
   | `completion.outcome`, `completion.wrong-timeline` | `decideCompleteTurn` |
   | `interrupt.retryable`, `interrupt.first-writer-wins` | `decideInterruptTurn` (+ `decideCompleteTurn`) |
   | `quarantine.release` | `decideInterruptTurn` + `decideReleaseQuarantine` |

2. **The known consumers do not duplicate the rules today.** `Gnostic`'s
   `FileTimelineRuntimeRepository` and `Yakamoz`'s SwiftData repository each embed an
   `InMemoryTimelineRuntimeRepository` and add journal replay or persistence around it. The
   issue's "three copies" evidence was true when it was written and is now stale. The live risk is
   the opposite: a durable adapter that embeds the in-memory actor must load or replay the whole
   history to decide one transition. `PKSQLiteStorage` ([#265](https://github.com/phynics/PositronicKit/issues/265))
   cannot embed it and would be the first true copy.

3. **Snapshot plus conditional commit is enough for every planned store.** Gnostic already
   replays an append-only journal; Yakamoz wraps a SwiftData transaction; SQLite would run one
   `BEGIN IMMEDIATE … COMMIT`. In each, loading the Timeline's Turns, messages, intents, results,
   and pointers, deciding in memory, and writing the returned rows inside one transaction is
   feasible. None needs a partial or streaming decision.

4. **Membership (#247) and quarantine (#285) fit.** Membership is an ordered list on the Turn, so
   every decision that appends a message also returns the updated list. Quarantine release is one
   more decision over the same snapshot and the same pointer rewrite.

5. **Call-site churn is one.** `grep -rn 'runtimeRepository\.' Sources/PositronicKit` finds 29
   call sites, and none has to change when the transition methods become protocol-extension
   helpers over a narrower seam.

## Decision

**The runtime owns a pure `TurnLedger`; the repository is an atomic-commit adapter.**

- `TurnLedger` is a stateless module of pure `decide…` functions. It reads a
  `TurnLedgerSnapshot` (the Timeline's Turns, messages, active and quarantine pointers, and a
  Turn's tool intents and results) and returns a `TurnLedgerDecision` carrying a `TurnLedgerCommit`
  — the exact rows to write: upserted Turns, appended messages, upserted tool intents and results,
  and the rewritten active/quarantine pointers. It never touches an actor, a database, or storage
  ordering.
- `InMemoryTimelineRuntimeRepository` becomes a thin adapter: load the snapshot, decide, apply the
  commit without an actor suspension. Its public protocol methods are unchanged for callers.
- The module is package-scoped in this change (`TurnLedger`, `TurnLedgerSnapshot`,
  `TurnLedgerCommit`, `TurnLedgerDecision`). No new public symbol lands until the protocol
  narrowing exposes the snapshot and commit values: an adapter implements the two new
  requirements, and the runtime's defaulted extension methods call the ledger, so the decision
  functions stay internal to the runtime.

**The protocol narrowing lands with the first adopting adapter.** Replacing the ten requirements
with `loadTurnLedger` and `commitTurnLedger` is a breaking protocol change that moves the
transition methods to a defaulted extension. It is not in this change: it would require both
platform API baselines and a migration note, and it has no in-repo consumer until `PKSQLiteStorage`
exists. Keeping the transition methods as requirements now means an adapter written before the
narrowing keeps compiling; the narrowing is one follow-up PR once `PKSQLiteStorage` proves the
shape. The runtime rules already have one owner.

**Conflict signalling stays at the storage boundary.** The loaded snapshot and the commit run in
one per-Timeline transaction. A concurrent writer either ran before the load or after the commit;
the adapter's uniqueness constraint on `(timeline_id, request_id)` and its single active-Turn
constraint are the durable backstop. This change adds no versioned ledger row, and does not need
one for the planned stores. A versioned compare-and-swap remains an option if a store without a
transaction boundary ever adopts the seam.

## Consequences

- The rules become testable as values: `Tests/PositronicKitTests/Services/TurnLedgerTests.swift`
  exercises admission, idempotency, busy and quarantine rejection, the tool barrier, tool-result
  atomicity, first-writer-wins completion, and quarantine release with no actor and no adapter.
- A durable adapter can decide one transition from a bounded read instead of embedding the whole
  in-memory repository.
- The conformance suite can shrink to atomicity, ordering, and round-trip checks once the protocol
  is narrowed; this change leaves it as the cross-adapter safety net.
- The in-memory actor remains the reference adapter and the host of the conformance suite.
- The ten transition requirements stay on the protocol for now. A third-party adapter still
  implementing them is unaffected by this change.

## Rejected alternatives

- **Narrow the protocol in this change.** It is a breaking change that needs a two-platform
  baseline regeneration, a migration note, and at least one adopter to prove the seam. Shipping
  the module first keeps one bounded behavior change per PR (AGENTS.md) and lets
  `PKSQLiteStorage` validate the shape.
- **Keep the rules per-transition in a shared free function that each adapter calls.** That is a
  weaker version of the same idea with no snapshot and no row set: the adapter still owns the
  append-only checks, pointer rewrites, and membership ordering, which are the divergent parts.
- **A versioned ledger row for conflict signalling.** No planned store needs it, and it adds a
  durable column every adapter must maintain. The storage transaction already serializes
  transitions.
- **Move the rules into `PKContracts`.** The rules read `TurnRecord`, `TimelineMessage`, and the
  repository errors; `PKContracts` imports no project target and must stay runtime-neutral.

## Relationships

- Amends ADR 0003 and ADR 0007: one repository still owns durability and atomicity; the runtime
  module owns the decision rules.
- Preserves ADR 0010: terminal finalization stays runtime-owned, and first-writer-wins is now a
  ledger predicate.
- Preserves ADR 0015: the snapshot and commit values become the public surface of the narrowed
  repository protocol; the ledger's decision functions stay internal.
- Records the prerequisite for [#265](https://github.com/phynics/PositronicKit/issues/265) and the
  follow-up for [#285](https://github.com/phynics/PositronicKit/issues/285).
