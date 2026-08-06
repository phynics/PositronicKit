# PKFAC-001 — Convert `PositronicKit` from value-type facade to `final class` config owner

**Priority:** P2
**Type:** Architecture / public API
**Depends on:** —
**Blocks:** PKFAC-002, PKFAC-004, PKFAC-005, PKFAC-006
**Triage:** wontfix
**Status:** Done — package commit `a8c84b4`; converted `PositronicKit` to a `final class` with one internally-owned prompt-history registry, and preserved genuinely new instances for `addPlugin`/`addStage`/`reconfigured` through a private shared-registry path.

Design: [`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md) §1.

### Summary

Replace the value-type `struct PositronicKit: Sendable` (`Sources/PositronicKit/PositronicKit.swift:28`)
with a long-lived, immutable reference-type owner:

```swift
public final class PositronicKit: Sendable { ... }
```

This is the structural spine every other PKFAC ticket builds on. Land it first with behavior
preserved (existing `run(_:)` entry, existing stores/wiring), changing only the type shape and the
cross-send-state ownership.

### Current problem

- `struct PositronicKit` is copied on every `addPlugin`/`reconfigured` (`PositronicKit.swift:250-278`,
  `:215-239`), and carries a shared `TimelinePromptHistoryRegistry` with a documented footgun: callers
  who reconstruct facades manually must thread *the same* registry instance through every rebuild or
  per-timeline prompt-diff and inspection-turn-index state silently resets (see the ~30-line doc
  comment at `PositronicKit.swift:58-70` and `:121-124`).
- Progressive disclosure today is construction-only; there is no clean owner to vend usage-level handles from.

### Implementation Requirements

- [ ] Change `struct` → `final class`; keep it `Sendable` (all mutable state stays behind the actors it
      holds — `TimelineManager`, `ToolRouter`, stores — so no lock/actor on the class itself).
- [ ] The class owns **exactly one** `TimelinePromptHistoryRegistry`, constructed internally, handed to
      every collaborator it builds. Remove the `promptHistoryRegistry:` init parameter (no consumer can
      construct a handle wired to the wrong registry).
- [ ] Replace value-copy builders: `reconfigured(...)` and the copy-based `addPlugin`/`addStage` semantics
      (`PositronicKit.swift:215-278`) become either mutation on the live instance or are removed. Audit all
      call sites first (grep Monad/Shuttle/Yakamoz + tests) and record the chosen replacement for each in
      the PR description. `reconfigured` existed only to preserve registry state across value copies — with a
      single owned registry the whole reason for it disappears.
- [ ] `timelineManager` / `toolRouter` stay public `let` for tier-3/tier-5 access (unchanged behavior).
- [ ] Vending is **synchronous** — no `async` added to obtain a collaborator.

### Acceptance Criteria

- [ ] `PositronicKit` is a `final class: Sendable`; no `promptHistoryRegistry:` param remains; footgun doc
      comments deleted.
- [ ] Existing `run(_:)` behavior and tests pass unchanged.
- [ ] Downstream grep across Monad/Shuttle/Yakamoz for `reconfigured`/`addPlugin`/value-copy assumptions;
      any breakage resolved in the same change (via local-path override until a compatible tag is cut).
- [ ] `make verify` green.
