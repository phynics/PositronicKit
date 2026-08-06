# JRN-2 — `TimelinePromptHistoryRegistry` never evicts: `removeHistory(for:)` is dead code

**Status:** Done — landed together with JRN-3 (see that ticket for test coverage). Made
`TimelinePromptHistoryRegistry.history(for:)` and `.removeHistory(for:)` `public` (pure visibility
widening; `TimelinePromptHistory` itself is now `public actor` too since it's the return type of a
public method — no behavior change, zero existing call sites of `removeHistory` anywhere in the
workspace before or after). Added a defensive LRU cap: new `RegistryEvictionPolicy` struct
(injectable via `TimelinePromptHistoryRegistry.init(thresholds:evictionPolicy:)`, default
`maxEntries: 1000`, same injectable-with-sensible-default pattern as `CompactionThresholds`):
when `history(for:)` would grow the registry past `maxEntries`, it evicts the
least-recently-*accessed* entry (both cache hits and creates count as access) before inserting the
new one. Recency tracked with a plain `[UUID]` access-order array (touch = remove + append; O(n)
per access but registry is capped and not a hot path) rather than a generic LRU abstraction, per
the ticket's "keep it proportionate" guidance. `Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift`.
Suggested follow-up (out of scope here, cross-repo): wire Monad's `TimelineAPIController` and
Yakamoz's `ConversationToolSupport.deleteConversation`/`TimelineStore.deleteTimeline` deletion
flows to call the now-public `removeHistory(for:)` directly, so eviction happens eagerly instead
of only via the LRU cap.
**Severity:** 🟠 Medium (process-lifetime memory growth)
**Repos:** PositronicKit (+ consumers' deletion flows)
**Source:** Journaling audit 2026-07-02

## Problem

`TimelinePromptHistoryRegistry` (`TimelinePromptHistory.swift:155-177`) holds an unbounded
`[UUID: TimelinePromptHistory]` keyed by timeline. `removeHistory(for:)`
(`TimelinePromptHistory.swift:174`, "e.g. when a conversation is deleted") has **zero call sites**
across PositronicKit, Monad, Shuttle, and Yakamoz (verified by grep). Deleting a conversation/
timeline anywhere leaves its history actor alive for the life of the process — a slow leak in a
long-running `MonadServer` and stale state in Yakamoz.

## Suggested direction

Wire timeline-deletion flows in consumers to call `removeHistory(for:)`; if deletion flows don't
exist yet, add a defensive LRU/TTL cap on the registry so it isn't unbounded process-lifetime
state. Test coverage belongs to JRN-3.
