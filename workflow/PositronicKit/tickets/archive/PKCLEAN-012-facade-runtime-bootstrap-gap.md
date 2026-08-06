# PKCLEAN-012 — `PositronicKit` facade wires dependencies but doesn't bootstrap a runtime

**Priority:** P3
**Type:** Docs / API design (decision needed)
**Depends on:** —
**Blocks:** —
**Triage:** wontfix
**Status:** Discarded (2026-07-09) — superseded by the **PKFAC facade-redesign series**
(`workflow/PositronicKit/specs/2026-07-09-positronickit-facade-redesign.md`).

### Why discarded

This ticket proposed an *additive* bootstrap ladder (`standalone(...)` / `bootstrapTimeline()` /
`bootstrapAgent()`) layered on top of the existing **`struct PositronicKit`** value-type facade.
A subsequent user-driven brainstorm chose a **ground-up redesign** instead: `PositronicKit`
becomes a long-lived `final class` configuration owner that vends managers/handles through a
named operation ladder (one-shot → Conversation → TimelineManager → AgenticRuntime → raw). That
replaces the value-type facade this ticket was built around, so the specific `standalone`/
`Bootstrapped` surface here is moot.

**Two decisions from this ticket are preserved in the new series (nothing lost):**
- *Facade owns its own `AgentInstanceManager`* (option (a), and the ordering rationale re: Monad's
  rebind at `MonadServerFactory.swift:91-108`) → carried into **PKFAC-006** (tier-4 `AgenticRuntime`).
- *Grouped init must expose `toolApprovalGate:`* → subsumed by **PKFAC-002** (grouped
  `Configuration`), and independently tracked by the pre-existing **PKAPI-008**.

### Decision (2026-07-09) — **build a progressive-disclosure bootstrap ladder (additive); facade owns `AgentInstanceManager`; agent bootstrap in v1**

Per the user: "PositronicKit should help discover different operation modes including different
levels of bootstrapping — a sort of progressive disclosure on the API level." Two Opus design
passes produced the concrete shape below. Agent bootstrap is **in scope for v1**; downstream
consumer migration timing is explicitly deferred (resolve the design/PositronicKit side now).

**The ladder (top = simplest, all share `TimelineManager.createTimeline` as the single seam):**

```
Tier 0  PositronicKit.standalone(llmService:) async -> Bootstrapped   // Yakamoz-shaped, batteries-included
Tier 1  init(llmService:persistence:runtime:) + bootstrapTimeline()   // opt-in convenience on the flexible init
Tier 2  init(llmService: … wide …), caller creates records itself     // Monad, Shuttle — unchanged
```

Each tier is the one below it with one convenience removed — a labeled shortcut, not a separate
code path.

**New public surface (all additive — no existing initializer signature changes):**

```swift
public extension PositronicKit {
    struct Bootstrapped: Sendable {
        public let kit: PositronicKit
        public let timelineId: UUID
        public let agentInstanceId: UUID?   // non-nil iff agentTemplate: was supplied
    }

    static func standalone(
        llmService: any LLMServiceProtocol,
        persistence: PersistenceConfiguration = .inMemory(),
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        runtime: RuntimeConfiguration = .default(),
        generationParameters: GenerationParameters? = nil,
        toolApprovalGate: any ToolApprovalGate = DenyAllToolApprovalGate(),
        timelineTitle: String = "New Conversation",
        agentTemplate: AgentTemplate? = nil
    ) async throws -> Bootstrapped

    @discardableResult func bootstrapTimeline(title: String = "New Conversation") async throws -> UUID
    @discardableResult func bootstrapAgent(from template: AgentTemplate) async throws -> UUID
}
```

`standalone` = `init(...)` + `bootstrapTimeline(...)` + optional `bootstrapAgent(...)` — one shared
bootstrap seam, not a parallel implementation.

**`AgentInstanceManager` ownership — option (a): the facade always builds its own.** Add a
`public let agentInstanceManager: AgentInstanceManager`, constructed in the designated initializer
immediately after `timelineManager` from stores the facade *already holds*
(`agentInstanceStore`/`timelinePersistence`/`messageStore`/`workspacePersistence` +
`resolvedWorkspaceRoot`) and injected with the facade's own `timelineManager` (preserves PKR-3
cache eviction on `deleteInstance`). `AgentInstanceManager` is a cheap reference-holding actor, so
eager construction on every facade is free — no lazy machinery. This is why Monad currently
throws away and *rebinds* its own manager (MonadServerFactory.swift:91-108): it needs the facade's
`TimelineManager`, which only exists post-construction — the exact ordering problem facade ownership
collapses. Monad is the only consumer that builds one (Shuttle/Yakamoz build none), so ownership is
purely additive.

**Rejected:** (b) an optional injected `agentInstanceManager:` param — reintroduces the
"built without the facade's TimelineManager" footgun the property kills; can be added additively
later if a real need appears. (c) lazy/on-demand — unwarranted for a free-to-build actor.
Auto-bootstrapping inside the existing inits — would give Monad/Shuttle a phantom default timeline;
bootstrap must stay opt-in.

**Also required (small, additive):** the grouped `init(…persistence:…runtime:…)` init does not
currently forward `toolApprovalGate:` — add it (defaulted) so Tier 0/Tier 1 can set the gate
without dropping to the wide init.

**Tests/examples:** `standalone(...)` returns a `timelineId` that `run(_:)` accepts with zero manual
setup; timeline + `WorkspaceReference` persisted; `agentTemplate:` non-nil yields a non-nil
`agentInstanceId` attached to the timeline; `bootstrapTimeline()`/`bootstrapAgent()` on a wide-init
facade produce the same persisted shape (proves the shared seam); regression: plain `init(llmService:)`
still creates **no** timeline (locks in the intentional empty-runtime contract). Add a "minimal
standalone chat" example to `PositronicKitExamples` as the first/simplest example. Update
`PositronicKit`'s type doc to state the ladder explicitly.

**Downstream (deferred, but the target state):** Monad deletes its `ManagerSet.agentInstanceManager`
+ rebind block and reads `coreChat.agentInstanceManager` (its `AgentInstanceAPIController` already
takes `any AgentInstanceManagerProtocol`, unchanged). Do NOT block the PositronicKit change on this.

### Summary

`PositronicKit.init` (`Sources/PositronicKit/PositronicKit.swift:127`) builds and wires
`TimelineManager`, `ToolRouter`, and `ChatEngine` from injected stores, but does not
create a timeline, a primary workspace, or an agent instance. `workspaceCreator` defaults
to `NullWorkspaceCreator()`, so with the simplified initializer
(`PositronicKit(llmService:)`) there is no workspace at all until a host explicitly
supplies a `WorkspaceCreating` and calls into `run()` with a `timelineId`, which lazily
hydrates via `resolveContextManager`.

This matches the type's own doc comment — *"Concepts like timelines, workspaces, agents,
and tool routing live here; concrete networking or multi-process hosting models are
expected to be provided downstream"* — so it may be working as designed: `PositronicKit`
is a dependency-wiring facade, not a runtime-bootstrapping one, and "primary workspace"
setup is intentionally a host concern (Monad/Shuttle/Yakamoz each have different
workspace-creation semantics).

The open question is whether that's still the right contract, or whether the facade
should offer a documented "batteries-included" path (e.g. a convenience
`PositronicKit.standalone(...)` or similar) for the common single-process/single-timeline
case, given `Yakamoz` is a local-only consumer that likely wants exactly that.

### Implementation Requirements

- [ ] Confirm current onboarding cost: how many lines/steps does each of Monad, Shuttle,
      Yakamoz currently spend re-implementing "create default timeline + primary
      workspace + agent" around the facade? (grep each consumer's
      `PositronicKit(...)` call sites and what surrounds them.)
- [ ] If the duplication is real and non-trivial, propose a convenience initializer or
      static factory that bootstraps a default timeline/workspace/agent for the
      single-process case, without changing the existing flexible-initializer contract.
- [ ] If duplication is minimal (each host's setup is genuinely different), document the
      current contract explicitly in `PositronicKit.swift`'s doc comment — state plainly
      that no timeline/workspace/agent exists until the host creates one — so this isn't
      re-discovered as a bug later.

### Acceptance Criteria

- [ ] Either a new convenience API lands with tests and `PositronicKitExamples` coverage,
      or the existing contract is documented as intentional with rationale.
- [ ] Downstream grep across Monad/Shuttle/Yakamoz if any convenience API changes what
      they're expected to call.
- [ ] `make verify` green; CHANGELOG updated if API surface changes.
