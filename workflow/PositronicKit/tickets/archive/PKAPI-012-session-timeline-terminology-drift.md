# PKAPI-012 — Session/timeline terminology drift in persistence protocol and internals

**Priority:** P3
**Type:** API design / naming
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, commit `457ee98`, merged into `main`) —
`TimelinePersistenceProtocol.saveTimeline`'s parameter label `_ session:` → `_ timeline:` (a
protocol requirement, but positional/`_`-labeled so it's non-breaking to compile — Swift matches
protocol conformance structurally, not by internal parameter name). `TimelineToolManager`'s logger
label `"session-tool-manager"` → `"timeline-tool-manager"`; `RuntimeToolPolicyFactory`'s internal
binding renamed to match (external label `for:` unchanged). Test name updated. Full `session` sweep
found no other genuine timeline-meaning stragglers. Downstream: Monad's `TimelineRepository`
conformer (`Monad/Sources/MonadServer/Services/Database/Repositories/TimelineRepository.swift:16`)
still spells the old parameter name — not required to compile, but should follow suit on its next
pin bump for consistency; noted in CHANGELOG rather than filed as a separate ticket (cosmetic,
non-blocking). `swift test` green (932 tests / 159 suites). CHANGELOG updated (Breaking, since it's
a protocol requirement even though structurally non-breaking here).

### Summary

The codebase's domain term is "timeline," but "session" survives in a few places —
presumably from a pre-rename era — creating exactly the kind of terminology fragmentation
already ticketed for `think`/`thinking`/`reasoning` (PKAPI-003). Confirmed instances:

1. **`TimelinePersistenceProtocol.saveTimeline(_ session: Timeline)`**
   (`Sources/PositronicKit/Services/Database/TimelinePersistenceProtocol.swift:8`) — the
   parameter is named `session` while the method, protocol, and type all say timeline.
   Every conformer (in-memory store, Monad's GRDB adapter, PKTestSupport mocks) inherits
   this contradiction in its signature.
2. **`TimelineToolManager`'s logger label** is `"session-tool-manager"`
   (`Sources/PositronicKit/Services/Timeline/TimelineToolManager.swift:31`) — log output
   attributes timeline-tool activity to a "session" module nobody can grep for by the
   type's name.
3. **Test naming**: `execute_unknownSession_throws`
   (`Tests/PositronicKitTests/ToolRouterConcurrencyTests.swift:60`) — test-only, lowest
   priority, but worth sweeping in the same pass.

A full `grep -rn "session" Sources/` should be run as part of this ticket to catch any
further stragglers (excluding legitimate uses, e.g. URLSession).

### Implementation Requirements

- [ ] Rename the `session` parameter to `timeline` in `TimelinePersistenceProtocol.saveTimeline`
      and all conformers (internal parameter name in conformers is cosmetic but should
      match; the protocol requirement's label is the API-visible part).
- [ ] Change the `TimelineToolManager` logger label to `"timeline-tool-manager"`.
- [ ] Sweep remaining "session" occurrences in `Sources/` (and tests) that refer to the
      timeline concept; rename or leave with justification.
- [ ] Downstream grep: Monad's GRDB persistence adapter conforms to
      `TimelinePersistenceProtocol` — external parameter names in protocol conformances
      must match, so Monad/Shuttle/Yakamoz conformers need the same rename.

### Acceptance Criteria

- [ ] No public API surface uses "session" to mean timeline.
- [ ] Logger labels match their owning type names.
- [ ] All three consumers compile.
- [ ] `make verify` green; CHANGELOG updated (protocol requirement parameter-name change
      is source-breaking for conformers).
