# PKFAC-006 — Tier 4: `AgenticRuntime` + facade-owned `AgentInstanceManager`

**Priority:** P2
**Type:** Public API / architecture
**Depends on:** PKFAC-001
**Blocks:** —
**Triage:** wontfix
**Status:** Done — facade-owned `AgentInstanceManager` and fresh `AgenticRuntime` wrapper implemented in `009f3cb`; focused tests and `make verify` passed.

Design: [`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md) §2 (tier 4).
Supersedes the agent-ownership decision from the discarded PKCLEAN-012.

### Summary

Add tier 4 of the ladder: `kit.agenticRuntime(...)` vending an `AgenticRuntime` — the public tier-4 face
over the existing `AgentInstanceManager` (`Sources/PositronicKit/Services/Agents/AgentInstanceManager.swift`).
No new orchestration logic; it is a wrapper/rename giving the agent tool-loop a named entry point.

### Facade-owned `AgentInstanceManager` (carried from PKCLEAN-012, option (a))

- Add `public let agentInstanceManager: AgentInstanceManager`, constructed in the designated initializer
  immediately after `timelineManager`, from stores the facade already holds (`agentInstanceStore` /
  `timelinePersistence` / `messageStore` / `workspacePersistence` + resolved workspace root) and injected
  with the facade's own `timelineManager` (preserves PKR-3 cache eviction on `deleteInstance`).
- Rationale: Monad currently throws away and *rebinds* its own manager
  (`MonadServerFactory.swift:91-108`) because it needs the facade's `TimelineManager`, which only exists
  post-construction — the exact ordering problem facade ownership collapses. `AgentInstanceManager` is a
  cheap reference-holding actor, so eager construction is free.
- **Rejected** (from PKCLEAN-012): optional injected `agentInstanceManager:` param (reintroduces the
  "built without the facade's TimelineManager" footgun); lazy/on-demand (unwarranted for a free actor).

### Open question to resolve

Spec §Open Questions: does `agenticRuntime(...)` vend fresh-per-call like conversations, or is
agent-instance identity distinct enough to warrant a different rule? Decide and record here.

### Implementation Requirements

- [ ] `public let agentInstanceManager: AgentInstanceManager` built in the designated init.
- [ ] `AgenticRuntime` type wrapping `AgentInstanceManager`'s agent tool-loop surface; `kit.agenticRuntime(...)`
      vends it against a timeline + workspace + agent instance.
- [ ] `agentInstanceManager` conforms to / is reachable as `any AgentInstanceManagerProtocol` (Monad's
      `AgentInstanceAPIController` consumes that protocol — unchanged).

### Acceptance Criteria

- [ ] Facade always exposes a ready `agentInstanceManager` wired to its own `timelineManager`.
- [ ] `agenticRuntime(...)` drives a full tool/agent loop end to end in a test.
- [ ] Downstream note filed for Monad to delete `ManagerSet.agentInstanceManager` + rebind block and read
      `coreChat.agentInstanceManager` (deferred to PKFAC-008; do NOT block this ticket on it).
- [ ] `make verify` green.
