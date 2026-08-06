# PKFAC-009 — `@Observable` Conversation wrapper (new `PKObservable` module)

**Priority:** P4
**Type:** Public API / SwiftUI ergonomics
**Depends on:** PKFAC-005
**Blocks:** —
**Triage:** wontfix
**Status:** Done — separate `PKObservable` product with cancellable `@Observable` conversation wrapper implemented in `ded69b5`; focused tests passed.

Design: [`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md) "Deferred to follow-up tickets".

### Summary

Core keeps `Conversation` a stateless, stream-returning **pure cursor** (PKFAC-005) and stays
SwiftUI-agnostic. This ticket adds an **opt-in** `@Observable` convenience that binds
`messages` / `isStreaming` / `streamingText` directly for SwiftUI, by consuming a cursor's `send`
stream and mirroring events into observable properties.

### Design decision (2026-07-09) — new opt-in module, not Yakamoz

Delivered as a **new PositronicKit package product**, `PKObservable`, alongside the existing
`PKOpenAIProvider`/`PKAnthropicProvider`/etc. targets — not folded into Yakamoz's `YakamozCore`.
Rationale: the wrapper is generic SwiftUI convenience over the public `Conversation` cursor, not
Yakamoz-specific glue; a workspace-level module lets Shuttle's operator UI or any future SwiftUI
consumer opt in without depending on Yakamoz. Yakamoz becomes a consumer of `PKObservable` like any
other SwiftUI-facing target, importing it rather than reimplementing it.

- Wraps a `Conversation` cursor; owns the live in-memory streaming buffer that core deliberately excludes.
- This is why core vends fresh cursors and defers observable state here: the "same live object across views"
  concern is solved by the wrapper being the observable object views bind to, not by caching in the kit.

### Implementation Requirements

- [ ] Add a `PKObservable` product/target to `PositronicKit/Package.swift`, depending on core
      `PositronicKit` (for `Conversation`/`ChatEvent`) only — no provider dependencies.
- [ ] `@Observable` type wrapping a `Conversation`; `send` mutates `messages`/`isStreaming`/`streamingText`.
- [ ] Cancellation of the in-flight stream is handled (view disappears / new send supersedes).
- [ ] Downstream: Yakamoz adopts `PKObservable` for its inspector-drawer chat surface once available
      (tracked here, not blocking PKFAC-008 or this ticket's core delivery).

### Acceptance Criteria

- [ ] Core `PositronicKit` target gains no SwiftUI dependency; `PKObservable` is a separate product.
- [ ] A SwiftUI view can bind to the wrapper and see streaming updates without manual stream iteration.
- [ ] `PKObservable`'s own gate green; `make verify-products` covers the new product.
