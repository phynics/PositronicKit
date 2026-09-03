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
sync; re-run `Scripts/annotate-guardrail-exceptions.py` after reviewing new sites
to regenerate annotations (it skips lines that already carry one).

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
`Tool`/`PKContracts.Tool` protocol mocks, each site annotated inline (see the
annotation reasons around `concurrency_unchecked_sendable` matches). Categories:

- **`PKTestSupport` mocks/stores** (`MockMessageStore`, `FailingStores`,
  `TestHTTPServer`, …): synchronous test doubles protected by
  `Synchronization.Mutex<State>` or immutable `let` captures.
- **`Tool`/`PKContracts.Tool` protocol mocks** (`MockTool`, `StubTool`, `FailingTool`,
  fixture tools in story tests): the tooling protocols are not `Sendable`-refined;
  the conformance is compiler-forced and stateless or capture-only.
- **Middleware/harness doubles** (`CapturingMiddleware`, `RecordingGate`,
  `LocalHTTPServer`, `BatchHarness`): bounded by `Mutex<State>` captures.
- **Pipe/lint fixtures** (`TestContext`): isolated per-test instances.

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

## Cancellation-aware permit boundaries

`FIFOLane` (`Sources/PositronicKit/Services/Concurrency/FIFOLane.swift`) stores keyed lane state
in `Synchronization.Mutex`, and its `PermitWaiter` stores one checked continuation inside a
separate mutex-protected lifecycle state. It is the single implementation behind every keyed
FIFO coordinator in the runtime — `AgentAuthorityCoordinator`, `ThreadAuthorityCoordinator`, and
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
