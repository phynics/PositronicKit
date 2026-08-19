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

These are the only `@unchecked Sendable` conformances in `Sources/`. Both are
external-framework boundaries that actor or mutex isolation cannot express, with a
documented invariant and focused test coverage.

### `MiniLMEmbedder` — `Sources/PKFastEmbed/PKFastEmbed.swift`

- **External type:** the native `CPKFastEmbed` C ABI (`pkfe_model_embed[_batch]`).
- **Why it is safe:** embedding serializes on a Rust `Mutex<TextEmbedding>` inside
  the native handle, all wrapper fields are `let`, and the sole production owner
  `PKMiniLMPlatformBackend` is an actor whose allocation/deallocation guarantees no
  embedding is in flight during `deinit` (`pkfe_model_destroy`).
- **Concurrent operations:** concurrent `embed(_:)` calls serialize natively.
- **Teardown owner:** the owning actor.
- **Why not actor/mutex:** the wrapper is storage-immutable; isolation would add
  dispatch without removing the native boundary.

### `StreamingLineDelegate` — `Sources/PKUtilities/ProviderHTTPTransport.swift`

- **External type:** `URLSessionDataDelegate` (Foundation), driven on a serial delegate queue.
- **Why it is safe:** the delegate queue serializes callbacks; the internal `NSLock`
  additionally guards the one-shot `CheckedContinuation` claim between cancellation
  and response delivery so it resumes exactly once.
- **Concurrent operations:** delegate callbacks (serial queue) vs the async caller's
  `awaitResponse()`/cancellation.
- **Teardown owner:** the owning `URLSession`.
- **Why not actor/mutex:** `URLSessionDataDelegate` is a synchronous Objective-C
  protocol; an actor boundary is impossible. This file is `#if`-gated Linux-only and
  its NSLock/continuation replacement is deferred until Linux validation is available.

## Test-support boundaries (retained)

`@unchecked Sendable` in `Tests/` is allowed only for synchronous test doubles and
`Tool`/`PKShared.Tool` protocol mocks, each site annotated inline (see the
annotation reasons around `concurrency_unchecked_sendable` matches). Categories:

- **`PKTestSupport` mocks/stores** (`MockMessageStore`, `FailingStores`,
  `TestHTTPServer`, …): synchronous test doubles protected by
  `Synchronization.Mutex<State>` or immutable `let` captures.
- **`Tool`/`PKShared.Tool` protocol mocks** (`MockTool`, `StubTool`, `FailingTool`,
  fixture tools in story tests): the tooling protocols are not `Sendable`-refined;
  the conformance is compiler-forced and stateless or capture-only.
- **Middleware/harness doubles** (`CapturingMiddleware`, `RecordingGate`,
  `LocalHTTPServer`, `BatchHarness`): bounded by `Mutex<State>` captures.
- **Pipe/lint fixtures** (`TestContext`): isolated per-test instances.

These doubles keep synchronous ergonomics deliberately (see AGENTS.md — test
doubles are not actorized solely to satisfy `Sendable`).

## Banned outright

- New type names ending in `Box`, `Cell`, or `Holder` in `Sources/`.
- Manual `NSLock` wrappers outside `ProviderHTTPTransport.swift`.
- Stored `CheckedContinuation`/`UnsafeContinuation`/stream continuations outside an
  explicit lifecycle state machine.
- Stored `Task` properties outside the actor or `@MainActor` owner of the task's
  cancellation.

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