# PKAPI-005 — Facade fluent-naming: `addPlugin`/`addStage` verb form, `getTimeline` side effect

**Priority:** P3
**Type:** API design / naming
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, commit `e8db60e`, merged into `main`) — `addPlugin(_:)` →
`addingPlugin(_:)`, `addStage(_:)` → `addingStage(_:)` (participle form, matching `reconfigured(...)`
on the same nonmutating value type; PKFAC-001's struct→final-class conversion had not landed at
implementation time). No downstream `.addPlugin(` call sites found. Second finding: `getTimeline(id:)`
is actually **public**, not package-internal as the ticket assumed, and is consumed directly by
Monad's `ChatAPIController`/`TimelineAPIController` — kept as-is for backward compatibility rather
than renamed/split-breaking. Added a pure `timeline(id:) -> Timeline?` query and an explicit
`touchTimeline(id:)` alongside it (additive); `ToolRouter`'s private-timeline check switched to the
pure query since it didn't need the touch side effect. `swift test` green (932 tests / 159 suites).
CHANGELOG updated (Breaking for the rename; Changed for the additive query/touch split).

### Summary

Two confirmed naming issues:

1. **`addPlugin`/`addStage` are nonmutating but use the imperative verb form.**
   `PositronicKit.addPlugin(_:)` (`Sources/PositronicKit/PositronicKit.swift:257`) and the
   internal `addStage(_:)` (line 248) both return a new `PositronicKit` copy (value type,
   nonmutating). Swift convention (matching `reconfigured(...)` at line 213, which gets
   this right) is that a nonmutating verb-named method uses the participle form —
   `addingPlugin(_:)` — because bare `add` implies in-place mutation.
2. **`TimelineManager.getTimeline(id:)` mutates as a side effect of a getter.**
   `Sources/PositronicKit/Services/Timeline/TimelineManager.swift:184-189` — the doc says
   "Retrieves a timeline by its ID and updates its updatedAt timestamp," and the body
   does exactly that: reads, mutates `updatedAt`, writes back, then returns. A
   `get`-prefixed method silently mutating internal state is a footgun for future callers
   who assume "get" means "read-only." (Note: this method is package-internal, not
   `public` — lower external blast radius, but still worth fixing since it's exactly the
   kind of thing that gets promoted to `public` later without anyone re-checking the
   naming.)

### Implementation Requirements

- [ ] Rename `addPlugin(_:)` → `addingPlugin(_:)` and `addStage(_:)` → `addingStage(_:)`
      (or make them `mutating func` if in-place mutation is actually the desired
      ergonomic — check how these are used in practice by Yakamoz/Monad/Shuttle before
      deciding value-type-copy vs. mutating is preferred going forward).
- [ ] Split `TimelineManager.getTimeline(id:)` into a pure `timeline(id:) -> Timeline?`
      query and an explicit `touchTimeline(id:)` (or fold the touch into whatever caller
      actually needs the side effect — check callers first to see if the mutation is
      needed on every call site or just some).

### Acceptance Criteria

- [ ] `addPlugin`/`addStage` renamed to participle form (or made `mutating`), call sites
      updated.
- [ ] `getTimeline` no longer silently mutates; side effect is either removed, made
      explicit via a separate method, or the name signals it (e.g. `touchAndGetTimeline`).
- [ ] Downstream grep for `addPlugin` (public API) across Monad/Shuttle/Yakamoz.
- [ ] `make verify` green; CHANGELOG updated if `addPlugin` renamed (public, breaking).
