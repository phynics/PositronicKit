# Concurrency Exception Manifest

Every concurrency "escape hatch" in PositronicKit must be listed here. This
manifest records the reviewed dispositions mandated by the reference-box
elimination work: ownership is explicit, and `@unchecked Sendable` survives only
where Swift cannot model an external boundary.

`.swiftlint.yml` enforces the manifest through five **global** custom rules that
flag any `@unchecked Sendable`, `NSLock`, stored continuation, stored task, or
`Box`-named holder type. Every reviewed occurrence carries an inline
`// swiftlint:disable:this <rule> -- <reason>` annotation on its own line naming
this manifest as the source of truth; any occurrence without an annotation fails
`make verify-concurrency-scan` (part of `make verify`, and a step in CI) via
`swiftlint lint --strict`. This file and the inline annotations must stay in
sync; review and annotate new sites directly before running the concurrency
gate.

## Production boundaries (retained)

The production boundaries with concurrency annotations are HTTP transport stream boundaries and
the cancellation-aware authority lane described below.

The Linux streaming bridge (`StreamingLineCoordinator` in
`Sources/PKUtilities/ProviderHTTPTransport.swift`, compiled only on non-Apple
platforms) is not an exception: it owns the `@unchecked`-free
`Mutex<StreamingLineState>` lifecycle state machine described under "Banned
outright" below, and its two stored continuations carry the sanctioned inline
annotations for exactly that reason.

## Test-support boundaries (retained)

`@unchecked Sendable` in `Tests/` is allowed only for synchronous test doubles and
`PKTool`/`PKContracts.PKTool` protocol mocks, each site annotated inline (see the
annotation reasons around `concurrency_unchecked_sendable` matches). Categories:

- **`PKTestSupport` mocks/stores** (`MockMessageStore`, `FailingStores`,
  `TestHTTPServer`, …): synchronous test doubles protected by
  `Synchronization.Mutex<State>` or immutable `let` captures.
- **`PKTool`/`PKContracts.PKTool` protocol mocks** (`MockTool`, `StubTool`, `FailingTool`,
  fixture tools in story tests): the tooling protocols are not `Sendable`-refined;
  the conformance is compiler-forced and stateless or capture-only.
- **Middleware/harness doubles** (`CapturingMiddleware`, `RecordingGate`,
  `LocalHTTPServer`, `BatchHarness`): bounded by `Mutex<State>` captures. The
  `RecordingOpenAIMiddleware` request signal is a one-shot `AsyncStream` continuation used only
  to stop the request consumer after the middleware has observed the outgoing request; its inline
  annotation documents that lifecycle.
- **Provider fixtures** (`ScriptedProviderHTTPTransport`, provider cancellation latches):
  actor-owned request and stream-termination waiters are registered before suspension and resumed
  exactly once by the corresponding event or cancellation callback.
- **Pipe/lint fixtures** (`TestContext`): isolated per-test instances.
- **ManualClock** (`Tests/PKTestSupport/ManualClock.swift`): actor-owned virtual-time waiters
  resume exactly once when a test advances the clock.

These doubles keep synchronous ergonomics deliberately (see AGENTS.md — test
doubles are not actorized solely to satisfy `Sendable`).

## Banned outright

- New type names ending in `Box`, `Cell`, or `Holder` in `Sources/`.
- Manual `NSLock` wrappers.
- Stored `CheckedContinuation`/`UnsafeContinuation`/stream continuations outside an
  explicit lifecycle state machine.
- Stored `Task` properties outside the actor or `@MainActor` owner of the task's
  cancellation.

## Actor-owned stream boundaries

`TurnEventHub` stores `AsyncThrowingStream` continuations inside its actor-owned
subscriber state. The actor is the sole owner of subscription, publication,
termination, and cancellation cleanup, so the continuation has an explicit
lifecycle rather than being shared through an unmanaged reference.

`TurnEventHub` also stores keyed `CheckedContinuation<Void, Never>` values for
`awaitTerminal(turnID:)` callers waiting on a Turn's terminal signal. Registration
happens fully inside the actor-isolated call before it can suspend, so a concurrent
`finish(turnID:)` can never miss a waiter that is mid-registration, and a
cancellation handler that removes a waiter can never race ahead of it being added —
both paths serialize through the same actor. `finish(turnID:)` resumes and clears
every waiter for that Turn; `awaitTerminal`'s `onCancel` hands cleanup to a Task
that re-enters the actor to resume and remove exactly its own waiter, the same
pattern already used by this file's subscriber `onTermination` cleanup.

## Runtime-owned terminal finalization

`TurnFinalizer` (`Sources/PositronicKit/Services/Turn/TurnFinalizer.swift`) is the runtime-owned
long-lived executor for terminal Turn commits (ADR 0010). Each commit runs in an unstructured
`Task` created inside the actor: it keeps task-locals, does not inherit the Turn's cancellation,
and holds the actor until the commit completes, so a submitted commit always finishes even if the
runtime is released before the store returns. Commits are deliberately not serialized per Timeline:
a Turn is only admitted after its predecessor is terminal in the store and `completeTurn` is
first-writer-wins, so a hung commit can never poison later commits. `TurnFinalizer` stores each
Turn's commit-handoff instant for in-process liveness classification.

`TerminalCommit` carries the stream `Continuation` the finalizer finishes after the durable commit,
the sinks, and the consumer-facing terminal events. The continuation's lifecycle is owned end to
end by the finalizer: yielded, finished, and released inside its detached commit task. Before the
hand-off, the Turn loop stores no continuation.

`TerminalStreamFailure` is a write-once envelope for a terminal stream error whose concrete type is
not statically `Sendable`. The Turn loop builds it once, the finalizer task reads it once while
finishing the stream, and it is never shared mutably. It exists only because a Turn's terminal
error comes from arbitrary provider and pipeline paths.

## Cancellation-aware permit boundaries

`FIFOLane` (`Sources/PositronicKit/Services/Concurrency/FIFOLane.swift`) stores keyed lane state
in `Synchronization.Mutex`, and its `PermitWaiter` stores one checked continuation inside a
separate mutex-protected lifecycle state. It is the single implementation behind every keyed
FIFO coordinator in the runtime — `AgentAuthorityCoordinator`, `TimelineAuthorityCoordinator`, and
`WorkspaceExecutionCoordinator` are thin typed wrappers over it, so this is now the one annotated
continuation site for all three.
Each waiter transitions exactly once from `pending` to `granted` or `cancelled`; cancellation
removes it from the lane and resumes its suspended task synchronously. This avoids an
unstructured cleanup task, prevents canceled waiters from being retained behind a hung operation,
and prevents a canceled caller from running its operation after it leaves the queue.

## Guardrail

> Do not introduce a generic reference box to satisfy a `Sendable` diagnostic or to
> mutate state from an asynchronous closure. First choose an owner. Use actor
> isolation for asynchronous state, `Mutex<State>` for synchronous state,
> asynchronous sequences for repeated signals, and structured task ownership for
> child work. Any remaining `@unchecked Sendable` requires a documented invariant in
> this manifest and a focused concurrency test.

## Commands

```bash
swiftlint lint --strict   # guardrail scan (runs in `make verify` and CI)
```
