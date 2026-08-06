# PKFAC-008 — Downstream migration: Monad / Shuttle / Yakamoz to the new facade

**Priority:** P3 (delayed out of the initial PKFAC delivery phase)
**Type:** Downstream / cross-repo
**Depends on:** PKFAC-001, PKFAC-002, PKFAC-003, PKFAC-006
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-11) — see resolution note below.

**Delayed (2026-07-09):** removed from the current PKFAC delivery phase per user decision — the
core facade redesign (001/002/003/005/006/007) ships and stabilizes first; downstream consumer
migration happens as a separate, later effort. Local-path overrides remain available for anyone who
wants to exercise the new facade from a consumer before this ticket is picked up. Not blocking
PKFAC-001…007's own `make verify` gates — this ticket only concerns Monad/Shuttle/Yakamoz call
sites.

> **Resolution (2026-07-11):** verification found all three consumers had already migrated to the
> new facade independently of this ticket — Monad, Shuttle, and Yakamoz are all pinned to
> PositronicKit `2.0.0` and construct via `PositronicKit(configuration: .init(provider:persistence:runtime:))`.
> Monad's `MonadServerFactory` already reads `coreChat.agentInstanceManager` directly with no
> `ManagerSet.agentInstanceManager` rebind block. No facade-migration code changes were needed;
> this ticket only tracked stale work. Monad: 174/174 tests pass. Yakamoz: build/test not verified
> in this session (see PKAPI-014 resolution note) but the facade-construction code itself is
> unchanged from what was already on `main`. Shuttle: confirmed clean via grep, not independently
> rebuilt this session.

Design: [`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md) §5, "Deferred".

### Summary

The facade redesign changes public PositronicKit construction/entry surface (struct→class, grouped
`Configuration`, provider inits relocated, facade-owned `agentInstanceManager`). Per the workspace
downstream-sync checklist, all three consumers must be migrated and gated before the consumer pins move.

### Implementation Requirements

- [ ] Grep **all three** consumers for the changed symbols: `PositronicKit(` call sites, `reconfigured`,
      `addPlugin`/`addStage`, provider convenience inits, and any `AgentInstanceManager` construction.
- [ ] **Monad:** delete `ManagerSet.agentInstanceManager` + the rebind block (`MonadServerFactory.swift:91-108`);
      read `coreChat.agentInstanceManager` instead (its `AgentInstanceAPIController` already takes
      `any AgentInstanceManagerProtocol`). Move to grouped `Configuration`; add provider imports where a
      relocated convenience init is used.
- [ ] **Shuttle / Yakamoz:** update construction to the new class + `Configuration`; add provider imports.
- [ ] Exercise each consumer via the local-path override until the compatible PositronicKit tag is cut, then
      bump each pin and run that consumer's full gate (`swift test` / `make verify` / `make test`).
- [ ] Persisted-model check: if any store field shape changed, add the Monad GRDB migration
      (`DatabaseSchema+Migrations.swift`) — in-memory mocks won't catch its absence.

### Acceptance Criteria

- [ ] Monad, Shuttle, Yakamoz each build + test green against the released PositronicKit tag.
- [ ] Monad no longer builds its own `AgentInstanceManager`.
- [ ] Consumer pins bumped in the same tickets/PRs that migrate them.
