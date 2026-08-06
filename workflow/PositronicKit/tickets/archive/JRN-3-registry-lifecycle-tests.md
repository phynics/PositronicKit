# JRN-3 — `TimelinePromptHistoryRegistry` lifecycle has no direct tests

**Status:** Done — landed together with JRN-2 (see that ticket for the eviction implementation
this covers). Added `TimelinePromptHistoryRegistryTests` (`Tests/PositronicKitTests/TimelinePromptHistoryTests.swift`,
Swift Testing, matching the existing file's framework) with 4 tests: (1) `history(for:)` called
twice with the same `timelineId` returns the same actor instance, verified by setting append
state via the first reference and observing it through the second; (2) `history(for:)` with two
different `timelineId`s returns isolated instances (state on one doesn't leak to the other); (3)
`removeHistory(for:)` followed by `history(for:)` yields a fresh instance (`appendedMessageCount`,
`appendedTokens`, and `lastDiff` all back at defaults); (4) exceeding `RegistryEvictionPolicy.maxEntries`
evicts the true least-recently-accessed entry, not an arbitrary one — fills the registry to its cap,
re-accesses the first-inserted timeline to refresh its recency, forces an eviction by adding one
more, and confirms the refreshed timeline survived (state intact) while the actually-stale one was
evicted (confirmed via getting a fresh/reset instance back for it). `swift test` green: 634 tests,
0 failures (full suite, two consecutive clean runs).
**Severity:** 🟠 Medium (untested load-bearing seam)
**Repos:** PositronicKit
**Source:** Journaling audit 2026-07-02

## Problem

Zero tests reference `TimelinePromptHistoryRegistry` or `removeHistory` (verified by grep over
`PositronicKit/Tests`). All `TimelinePromptHistoryTests.swift` tests construct a bare
`TimelinePromptHistory()` directly (e.g. `:55,118,147`), bypassing the registry that `ChatEngine`
actually uses (`ChatEngine.swift:47`, `PositronicKit.swift:137,406`). The registry's core purpose
— one instance per timeline across `execute()` calls (the YAK-16-adjacent stable-prefix fix) — is
only validated indirectly end-to-end (`Yakamoz InspectableChatIntegrationTests.swift:309`).

## Suggested direction

Add a `TimelinePromptHistoryRegistryTests` suite: reuse for same `timelineId`, isolation across
different ids, and `removeHistory` → `history(for:)` yields a fresh instance (nil base snapshot).
Do together with JRN-2 so eviction behavior is specified when it gains callers.
