# PKPOST-004c: `ToolProviding` — assemble turn tools from workspaces + globals

**Priority:** P3
**Type:** Feature/refactor (public API — release-triggering ticket; tag per PKPOST-002)
**Depends on:** PKPOST-004a, PKPOST-004b
**Blocks:** None
**Triage:** ready-for-human
**Status:** Done (2026-07-06)

**Resolution:** Implemented in PositronicKit `72ec444`: `ToolProviding` protocol,
`TimelineToolManager.registerToolProvider(_:id:)`, default `WorkspaceProtocol.executeTool`
sink. Consumer migration completed in Monad `c69bdf2` and Yakamoz `e32ba28`; release
tagged `1.1.0` and consumers repinned per PKPOST-002.

## Summary

Introduce `ToolProviding` (spec D1) and have the facade/`TimelineManager` assemble each
turn's tool set from attached workspace providers plus explicitly-registered global tools,
instead of consumers hand-flattening `[AnyTool]`. `ToolRouter.processToolCalls` keeps its
flat input (internal). Delete the dead `LocalWorkspace.executeTool` stub path
(`Monad/Sources/MonadServer/Models/Workspace/LocalWorkspace.swift:29`) as part of consumer
migration; Monad's HTTP `listTools` becomes a projection of `provideTools()`;
`WorkspaceProtocol.listTools/executeTool` stops being presented as the runtime's tool
source (spec D1 rationale).

Consumer migration (downstream-sync checklist applies — Monad, Shuttle, Yakamoz):
- Yakamoz: `YakamozRuntime.resolveTools` (`Sources/YakamozCore/Runtime/YakamozRuntime.swift:118`)
  becomes folder/terminal/built-in `ToolProviding` conformances; Compose-pane grouping reads
  `ToolProvenance` instead of `requiresWorkspace`/`requiresTerminal` flag filtering.
- Shuttle: recompile only (no usage of either surface).
- Monad: `WorkspaceAPIController`/`RemoteWorkspace` RPC surface unchanged.

## Acceptance Criteria

- [ ] Turn tool assembly from multiple providers preserves per-provider provenance;
      execution routes to the owning workspace by construction.
- [ ] Exactly one canonical provision surface presented publicly; examples updated.
- [ ] All three consumers compile + gates pass against a local-path override; release
      tagged and consumers repinned per PKPOST-002 before closing.
- [ ] `make verify` + `make verify-products` green.
