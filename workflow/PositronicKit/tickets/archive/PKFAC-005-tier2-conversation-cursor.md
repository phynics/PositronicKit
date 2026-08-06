# PKFAC-005 — Tier 2: `Conversation` cursor + vending

**Priority:** P2
**Type:** Public API
**Depends on:** PKFAC-001
**Blocks:** PKFAC-009 (deferred)
**Triage:** wontfix
**Status:** Done — pure `Conversation` cursor and vending implemented in `009f3cb`; focused tests and `make verify` passed.

Design: [`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md) §2 (tier 2), §3.

### Summary

Add the conversation tier: a lightweight, `Sendable`, `Identifiable` **pure cursor** over the kit-owned
stores + registry, vended fresh per call.

```swift
public func newConversation(title: String = "New Conversation") async throws -> Conversation
public func conversation(timelineId: UUID) -> Conversation

public struct Conversation: Sendable, Identifiable {
    public var id: UUID { timelineId }
    public let timelineId: UUID
    public func send(_ message: ...) async throws -> AsyncThrowingStream<ChatEvent, Error>
    // escape hatch → tier 3
    public var timelineManager: TimelineManager { get }   // scoped access
}
```

### Design constraints (from spec §3)

- **Pure cursor:** holds NO live in-memory turn state. All in-flight-turn / cancellation / subscriber
  coordination lives in the kit-owned actors (`TimelineManager` / a per-id turn actor), not the handle.
- **Fresh per call:** `conversation(timelineId:)` returns a new handle each time; two handles for the same
  id point at the same underlying state. No caching in the kit (rejected: `[id: Handle]` map — reintroduces
  mutable state + eviction/lifecycle burden).
- **SwiftUI identity:** `id == timelineId`, minted once at `newConversation()` and persisted; re-fetching a
  fresh handle causes no view churn.
- **`send` returns `AsyncThrowingStream<ChatEvent, Error>`** (matches today's `run`/`ChatEvent`). No
  `@Observable` in core — that is PKFAC-009 (deferred, downstream).

### Implementation Requirements

- [ ] `newConversation()` mints the `timelineId` once via `TimelineManager.createTimeline` (the shared seam)
      and persists timeline + `WorkspaceReference`.
- [ ] `conversation(timelineId:)` is a pure lookup cursor; no persistence side effect on construction.
- [ ] `send` delegates to the existing `run(_:)`/ChatEngine path for that `timelineId`.
- [ ] Escape hatch exposes scoped `TimelineManager` access for tier-3 escalation without returning to `kit`.

### Acceptance Criteria

- [ ] Two `conversation(timelineId: x)` calls return distinct handles with equal `.id`, both reading the same
      persisted state.
- [ ] Multi-turn send remembers history across sends on the same handle id.
- [ ] `Conversation` is `Identifiable`; a SwiftUI-style `ForEach` over ids is stable across re-fetch (unit
      test asserting `.id` stability).
- [ ] `make verify` green.
