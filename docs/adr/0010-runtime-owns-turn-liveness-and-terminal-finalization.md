---
status: proposed
---

# Runtime owns Turn liveness and terminal finalization

ADR 0003 makes the runtime repository
own Turn durability, including stale-Turn recovery. This ADR keeps durability in the repository
but moves **deciding** that a Turn is abandoned, and **driving** its terminal commit, into the
runtime. It supersedes only the stale-Turn recovery part of ADR 0003. Admission, idempotency, and
the atomic terminal boundary are unchanged. Issues #195 and #207 motivate it.

## Context

The Turn task commits its own terminal outcome. When that task is cancelled, a host store that
checks cancellation fails the commit and leaves the durable Turn active (#195). Protecting the
commit from cancellation fixes that, but then a store call that hangs can no longer be interrupted
(#207). Timeline eviction cancels the Turn and waits for its task with no limit, because tools and
persistence must not run against a torn-down Timeline, so a single hung store call stalls eviction.
`withTaskCancellationShield` needs Apple OS 27 and the deployment targets stay at macOS 15 and
iOS 18 (#194), so the fix cannot rely on it.

The repository already has the pieces for recovery, but they sit in the wrong place. `recover`
compares `updatedAt` against a store-configured `staleAfter`, yet nothing renews `updatedAt` while
a model streams or a tool runs, and the runtime never calls `recover`. `interruptTurn(force:)`
both overrides an already-terminal Turn and blocks the Timeline, whether or not anything unsafe
happened. `failTurn` and `cancelTurn` repeat `completeTurn(outcome:)`. What holds up well is
first-writer-wins: `completeTurn` on a terminal Turn returns the durable record unchanged.

## Decision

**A runtime-owned `TurnFinalizer` performs terminal commits.** The Turn loop decides the outcome,
hands the decision and a snapshot of partial output to the finalizer, and exits. The finalizer
commits the outcome, runs the sinks, releases the reservation, and emits the terminal event, in
the order `commitTerminal` uses today, serialized per Timeline. It holds only the repository,
sinks, event hub, and snapshot, never workspace, tool, or Timeline-cache state. Cancelling a Turn
cannot cancel its commit, because the finalizer is not the cancelled task. The finalizer is a
documented long-lived runtime task in the concurrency exception manifest.

**Eviction has two phases.** Phase one returns immediately: it bumps the Timeline liveness
version, cancels the Turn, rejects new work, and drops the Timeline from the cache. Phase two
removes the ephemeral workspace directory and releases registries after the Turn task exits.
Because the Turn task no longer waits on the store, phase two is not held up by a hung commit, and
no tool runs after its workspace is removed. Permanent deletion keeps refusing while a durable
Turn is active.

**Liveness is in-process, and a runtime process owns its store.** PositronicKit assumes one
runtime process owns a `TimelineRuntimeRepository` at a time, and documents that as a consumer
requirement. The store records no heartbeat and the runtime runs no timers. When admission meets
`timelineBusy`, or when a Timeline loads, the runtime classifies the active Turn:

- A Turn in this process's registry that is making progress, or whose terminal commit has been
  pending no longer than `RuntimeConfiguration.terminalCommitStallLimit`, stays busy.
- A Turn whose terminal commit has been pending longer than that limit is interrupted.
- An active Turn this process does not own is an orphan from an earlier or crashed process and is
  interrupted immediately.

After interrupting, admission is retried once. The stall limit defaults to five minutes and is
measured with the injected clock.

**Quarantine requires evidence.** An interrupted Turn is retryable: the Timeline is released and
the same request ID may be retried as a linked attempt. It is quarantined instead only when a retry
could repeat a side effect, which means the Turn has an unresolved tool intent for a `.mutating` or
`.externalProcess` tool. A quarantined Timeline rejects admission until an operator releases it.

**The repository interface narrows to match.**

```swift skip
func completeTurn(turnID: UUID, outcome: TurnOutcome, finalMessage: TimelineMessage?,
                  terminalHandle: TurnTerminalHandle?, now: Date) async throws -> TurnRecord
func interruptTurn(turnID: UUID, reason: String,
                   disposition: TurnInterruptDisposition, now: Date) async throws -> TurnInterruptResult
func releaseQuarantine(timelineID: UUID, turnID: UUID,
                       confirmation: QuarantineReleaseConfirmation, now: Date) async throws -> TurnRecord

enum TurnInterruptDisposition { case retryable, quarantined(String) }
enum TurnInterruptResult { case interrupted(TurnRecord), alreadyTerminal(TurnRecord) }
```

`completeTurn` is the only way to record a terminal outcome, and `interruptTurn` is the only way to
record an abandoned one. Both are first-writer-wins: neither overwrites a terminal Turn, and
`interruptTurn` reports `.alreadyTerminal` when the owner's commit landed first. `failTurn` and
`cancelTurn` become extension conveniences over `completeTurn`. `recover`, `TurnRecoveryResult`,
`forceClear`, the `force` flag, and the in-memory store's `staleAfter` are removed.
`TurnRecord.requiresRecovery` and `recoveryMessage` become `quarantine: TurnQuarantine?`, and the
admission error `recoveryRequired` becomes `timelineQuarantined`.

## Consequences

A late commit from a hung store cannot corrupt state: once the runtime interrupts the Turn, the
late `completeTurn` returns the interrupted record. Nothing on the commit path has a timeout, so the
durable outcome is never ambiguous. A hung commit bounds how long a Timeline stays busy, not how
long eviction takes. If the whole store hangs, `interruptTurn` hangs too; the runtime cannot fix
that, and it no longer blocks eviction.

The single-owner assumption rules out several processes sharing one store. Supporting that later
needs an owner token recorded at admission, which is a store change this ADR does not make.

This is a breaking change for every `TimelineRuntimeRepository` conformer, shipped in the same
breaking release as the Swift 6.4 floor (#194). `TimelineRuntimeRepositoryConformanceSuite` swaps
its `recover` and `forceClear` cases for interrupt dispositions, first-writer-wins between
`completeTurn` and `interruptTurn`, and quarantine release. `docs/Architecture.md` and
`docs/Testing.md` stop describing store-side stale recovery. The #195 `Task {}` wrapper is not
needed; its cancellation-durability tests move to the finalizer.

When this ADR is accepted, ADR 0003 gains a note that stale-Turn recovery is governed here.

## Rejected alternatives

- **Time out the commit.** The store may commit after the timeout, leaving the durable outcome
  ambiguous, and a timeout cannot stop the store's work.
- **Bound only eviction's wait.** The Turn task would outlive teardown and run tools against a
  removed workspace.
- **No limit, document a contract.** The library cannot enforce it, and one hung store stalls
  eviction indefinitely.
- **Store heartbeats and staleness.** They add a write per heartbeat interval to every store and
  still misjudge long model rounds unless renewed during streaming. Under the single-owner
  assumption, in-process liveness gives the same answers without a store change.
- **`#available` use of `withTaskCancellationShield`.** It creates a second execution path (#194),
  and it addresses only cancellation, not hangs.
