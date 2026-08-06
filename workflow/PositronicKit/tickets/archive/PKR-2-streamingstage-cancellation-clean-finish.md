# PKR-2 — `LLMStreamingStage` treats cooperative cancellation as clean completion

**Status:** Done — replaced `if Task.isCancelled { break }` with `throw CancellationError()` in `LLMStreamingStage.streamResponse`, mirroring the proven `.streamTimedOut` throw path: the throw exits before `flushRemainingBuffer`/`finalizeTurn` and surfaces through `continuation.finish(throwing:)`, so `ChatEngine`'s `catch is CancellationError`/`isCancellationOrigin` unwrap persists `.cancelled` + yields `.generationCancelled()` (STAB-1). A deterministic unit test of the race branch is infeasible (`AsyncThrowingStream.next()` returns nil on cooperative cancellation before the loop body re-evaluates `Task.isCancelled` with a buffered value); end-to-end `.cancelled` persistence for a stage-thrown `CancellationError` is covered by STAB-1's `streamCancellationAfterTextPersistsCancelledAssistant`. `swift test` green (628).
**Severity:** 🔴 High (truncated response persisted as `.complete`)
**Repos:** PositronicKit
**Source:** PositronicKit review 2026-07-02

## Problem

In `streamResponse` (`Sources/PositronicKit/Services/Chat/Stages/LLMStreamingStage.swift:88-100`,
verified), the delta loop does `if Task.isCancelled { break }`, then unconditionally
`flushRemainingBuffer` + `finalizeTurn` and returns normally. The enclosing task group
(`:46-67`) sees a successful child, `continuation.finish()` runs as if the turn completed, and
`MessagePersistenceStage` persists a possibly-truncated response as a normal `.complete` message —
bypassing the STAB-1 `.partial`/`.cancelled` status machinery entirely. Only the idle-timeout
path (`.streamTimedOut`) correctly throws.

Failure scenario: the streaming task gets cancelled through structured concurrency for any reason
other than the user-cancel path `ChatEngine` handles explicitly — the turn is recorded complete
with silently missing tail content.

## Suggested direction

Replace `break` with `throw CancellationError()` (letting `ChatEngine`'s existing
`CancellationError` catch yield `.generationCancelled()` and persist `.cancelled`), or otherwise
distinguish "task cancelled" from "stream ended". Add a test: cancel mid-stream at the stage
level and assert the turn is not finalized as complete.
