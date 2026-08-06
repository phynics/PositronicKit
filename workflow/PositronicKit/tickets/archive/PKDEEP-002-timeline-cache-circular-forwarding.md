# PKDEEP-002 — Deepen TimelineManager by collapsing the circular TimelineCache seam

**Priority:** P2
**Type:** Research / architecture-review follow-up (deepening candidate)
**Depends on:** none
**Blocks:** PKDEEP-007 (folded cleanup of `TimelineCache` hypothetical seam lands with this)
**Status:** Done (promoted → PKDEEP-002-impl)
**Resolution:** Research complete. Finding: **PROMOTE**. PKARCH-003's test-isolation justification is
hollow — `FakeTimelineCache` tests a mirror of the actor's own dictionaries; the actor-level test
surface (`TimelineManagerTests` + `WorkspaceAttachmentTests`, 562 lines) is already richer. The
circular re-entry (`Manager → Service → Manager-via-protocol`) is not justified. Both services are
stateless `struct`s — folding into the actor makes `await cache.cacheX()` hops collapse to
synchronous dict access (strict concurrency simplification). Zero downstream references. Chosen
shape: **option (a)** — one large actor with extension files (`TimelineManager+Lifecycle.swift`,
`TimelineManager+Attachments.swift`). `RuntimeToolPolicyFactory` stays (pure helper, real test
surface, no circular dependency). Delete `TimelineCache.swift` (protocol + conformance),
`TimelineLifecycleService.swift`, `WorkspaceAttachmentService.swift`, `FakeTimelineCache.swift`,
`TimelineLifecycleServiceTests.swift`, `WorkspaceAttachmentServiceTests.swift`. Port unique test
cases into actor-level suites. Net ~470 source lines deleted, ~470 recreated (folded); ~426 test
lines deleted, ~170-210 added. Public API byte-identical. PKARCH-003 superseded.

### Summary

`TimelineManager` (an actor that owns the timeline / context-manager / tool-manager /
active-task caches) forwards its public lifecycle and workspace-attachment methods to two
package-internal services — `TimelineLifecycleService` and `WorkspaceAttachmentService` —
which then *re-enter* the manager via the 9-method `TimelineCache` protocol to mutate the
state the manager itself owns. The call path
`Manager.createTimeline` → `LifecycleService.createTimeline` → `Manager.cacheSetTimeline`
is a circular-forwarding dance. `TimelineCache`'s only production adapter is
`TimelineManager` itself; the only fake is `Tests/PositronicKitTests/Services/FakeTimelineCache.swift`.
This is the canonical "one adapter = hypothetical seam" pattern. The candidate is to
consolidate lifecycle + attach code back into `TimelineManager`, retire the
`TimelineCache` protocol, and exercise the actor through injected `Stores` (which already
exists). `RuntimeToolPolicyFactory` (a pure helper) stays.

**Conflict note with PKARCH-003 (closed, commit `01e871a`):** PKARCH-003 *introduced* this
split on 2026-07-07 as a deliberate locality extraction ("split `TimelineManager` into
three package-internal services behind a narrow `TimelineCache` seam; `TimelineManager`
is now a thin coordinator/cache owner with byte-identical public surface"). This candidate
is therefore in direct tension with a recently-closed ADR-equivalent ticket. The research
gate is to determine whether the extraction's locality gain (test isolation of the three
services) outweighs the friction (circular re-entry, protocol-with-one-adapter, 9 cache
methods mirroring private dicts). Worth reopening because the extraction shipped same-day
as this review and the friction is real — but the prior decision carries weight and must
be explicitly re-litigated, not silently reverted.

### Current problem (with file:line references)

- `Sources/PositronicKit/Services/Timeline/TimelineManager.swift` (~358 lines) — actor
  owning `timelines`, `contextManagers`, `toolManagers`, `activeTasks` dictionaries; public
  methods `createTimeline`, `hydrateTimeline`, `attachWorkspace`, etc. forward to
  `lifecycleService` / `attachmentService`.
- `Sources/PositronicKit/Services/Timeline/TimelineLifecycleService.swift` (~248 lines) —
  cannot touch the caches directly; calls back into `TimelineManager` via the
  `TimelineCache` protocol (`cache.cacheSetTimeline(...)`, `cache.cacheReadTimeline(...)`,
  `cache.cacheEvictAll(...)`, etc.).
- `Sources/PositronicKit/Services/Timeline/WorkspaceAttachmentService.swift` (~128 lines) —
  same pattern; forwards to `TimelineManager`'s caches via the protocol.
- `Sources/PositronicKit/Services/Timeline/TimelineCache.swift` (~97 lines) — 9-method
  protocol whose only production conformer is `TimelineManager` itself.
- `Sources/PositronicKit/Services/Timeline/RuntimeToolPolicyFactory.swift` (~64 lines) —
  pure stateless helper (`createToolManager`); survives any restructuring.
- `Tests/PositronicKitTests/Services/FakeTimelineCache.swift` — the only other conformer;
  exists solely to enable testing the two extracted services in isolation.

**Deletion test result:** complexity vanishes. Delete `TimelineLifecycleService`,
`WorkspaceAttachmentService`, and `TimelineCache`. The public surface of
`TimelineManager` stays identical (it already re-exports those methods). The circular
`await cache.cacheX(...)` hops collapse to in-actor dictionary access. The fake-cache
tests are recast as `TimelineManager` tests with injected `Stores` (which already exists
for the persistence seam).

### Research scope

1. **Re-litigate PKARCH-003 explicitly.** Re-read `workflow/PositronicKit/tickets/archive/`
   for the PKARCH-003 ticket; summarize the *stated* rationale for the split (likely:
   "test isolation of lifecycle / attach / tool-policy concerns"). Decide whether the
   stated gain still holds given that the sole fake (`FakeTimelineCache`) tests a
   mirror-image interface — i.e. the tests assert the services call the right cache
   methods, not that the lifecycle behaviour is correct. The deeper test surface is the
   actor itself with injected `Stores`.
2. **Audit the call graph.** Grep for every call site of
   `TimelineLifecycleService`, `WorkspaceAttachmentService`, `TimelineCache`,
   `FakeTimelineCache` across the workspace. Confirm:
   - The two services have no caller outside `TimelineManager` (expected: zero).
   - `TimelineCache` has no conformer outside `TimelineManager` and the test fake.
   - The 9 cache methods are not re-used by any other type.
3. **Test churn estimate.** List every test that uses `FakeTimelineCache` or constructs
   the two services directly. Estimate lines to recast as `TimelineManager` + injected
   `Stores` tests. Note whether the recast loses *coverage* of any failure mode; if
   coverage stays equal or grows, the recast is safe.
4. **Actor-size check.** Folding the two services back into `TimelineManager`
   approximately adds 248 + 128 ≈ 376 lines. With the existing 358, the actor approaches
   ~700 lines. Decide: (a) accept one large actor with *internal seams* via private
   extension files in the same target (`TimelineManager+Lifecycle.swift`,
   `TimelineManager+Attachments.swift`), or (b) keep the split but drop the protocol —
   services receive `TimelineManager` directly (no `TimelineCache` re-entry) via
   package-internal friend access. Both are deepening options; (a) is the deeper module,
   (b) keeps file-level locality without the seam. Pick one as the deepening shape and
   justify.
5. **Sendability / actor-isolation check.** Confirm whether `TimelineLifecycleService`
   and `WorkspaceAttachmentService` were made `actor`s in the PKARCH-003 split (if yes,
   folding back is trivial — they're already isolated to the same executor). If
   they're `struct`s/`class`es touching the caches via the protocol, the fold requires
   merging their methods into `TimelineManager`'s actor isolation.
6. **Downstream impact.** Grep Monad, Shuttle, Yakamoz for `TimelineLifecycleService`,
   `WorkspaceAttachmentService`, `TimelineCache`. Expected: zero (all `package`-internal).
   If anything external references them, the deepening must preserve those names or
   coordinate a consumer release.

### Acceptance criteria

- [ ] PKARCH-003 rationale summarized; explicit decision recorded whether to re-open it.
- [ ] Call-graph audit results recorded (services, protocol, fake, 9 cache methods).
- [ ] Test churn estimate produced; coverage-delta stated (equal/grows/shrinks).
- [ ] Deepening shape chosen: (a) one large actor with internal-seam extension files **or**
      (b) split kept, protocol dropped, services receive `TimelineManager` directly.
      Justified against the actor-size and isolation findings.
- [ ] Downstream grep clean (or named external callers identified for coordination).
- [ ] Final finding: **promote** (file `PKDEEP-002-impl` implementation ticket; if it
      reverts PKARCH-003, the impl ticket must explicitly supersede PKARCH-003 in its
      resolution note and add an ADR) **or reject** (state the load-bearing reason;
      record an ADR forbidding re-suggestion if the reason would survive future reviews).
- [ ] If implemented, PKARCH-003's archived ticket is annotated with a "superseded by
      PKDEEP-002-impl on <date>" line.

### Downstream sync

Research-only; no implementation here. Any subsequent implementation is
package-internal-only by default (the public `TimelineManager` surface is preserved).
If the impl ticket later exposes a new public type (e.g. an `Attachments` sub-namespace),
grep all three consumers before landing.