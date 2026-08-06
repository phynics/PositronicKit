# PKFAC-004 — Tier 1: one-shot `complete` / `stream`

**Priority:** P3
**Type:** Public API
**Depends on:** PKFAC-001 *(done — package commit `a8c84b4`, archived 2026-07-10; this ticket is unblocked)*
**Blocks:** —
**Triage:** wontfix
**Status:** Done — direct `LLMStreamClient` one-shot APIs implemented in `923dac9`; focused tests passed and the implementation was integrated into `main`.

> **Decision 2026-07-10 (user):** implement tier 1 as **facade sugar directly over `LLMStreamClient`
> — no timeline created at all.** Do not spin an ephemeral timeline. This guarantees zero persistence
> by construction (no in-memory stores to leak from) and needs no new runtime support; tier 1 has no
> tools or context, so it doesn't need the `run(_:)` turn loop. `complete` awaits and returns the
> assembled final text; `stream` forwards the token/event stream from the client. The
> ephemeral-timeline regression test still applies as a guard (assert no store rows exist after a
> call), but with the direct path it should be trivially satisfied.

Design: [`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md) §2 (tier 1), Open Questions.

### Summary

Add the shallowest rung of the operation ladder — prompt-in / text-out with no persistence and no tools:

```swift
public func complete(_ prompt: ...) async throws -> String
public func stream(_ prompt: ...) -> AsyncThrowingStream<...>
```

### Open question to resolve first

The spec flags: does tier 1 need genuine timeline-free execution in the runtime, or is it a thin wrapper
that spins an ephemeral, non-persisted timeline (in-memory stores, discarded after)? Resolve this before
implementing — it determines whether new runtime support is needed or this is pure facade sugar over
existing `run(_:)`/`LLMService`. **Triage stays `needs-info` until this is decided.**

### Implementation Requirements

- [ ] Decide ephemeral-timeline vs. direct-`LLMService` path; record the decision in this ticket.
- [ ] `complete` returns the final assembled text; `stream` returns the token/event stream.
- [ ] No persistence side effects observable after the call (regression test: stores unchanged).
- [ ] Add as the first, simplest example in `PositronicKitExamples`.

### Acceptance Criteria

- [ ] `kit.complete("hi")` works with only `PositronicKit(llmService:)` — zero setup.
- [ ] No timeline/message rows persisted by a tier-1 call.
- [ ] `make verify` green.
