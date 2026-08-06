# PKV3-002 — Make workspace roles explicit and inject WorkspaceResolver

**Priority:** P1
**Type:** Breaking API / architecture
**Depends on:** —
**Blocks:** PKV3-006
**Triage:** ready-for-agent
**Status:** Done (2026-07-13, PositronicKit branch `pkv3-track2-workspace-timeline` commit `e74a742`)

**Resolution:** Renamed the overlapping workspace names to explicit roles — `WorkspaceProtocol` →
`Workspace`, `WorkspaceCreating` → `WorkspaceFactory`, `WorkspacePersistenceProtocol` →
`WorkspaceStore`, `AgentWorkspaceServiceProtocol` → `WorkspaceCatalog` (concrete
`AgentWorkspaceService` → `DefaultWorkspaceCatalog`), `WorkspaceManagerProtocol` →
`WorkspaceResolver` (concrete `WorkspaceManager` → `DefaultWorkspaceResolver`). `TimelineManager`
now exposes `workspaceResolver: any WorkspaceResolver` and gains a designated initializer taking
`resolver: any WorkspaceResolver` directly, so it no longer composes
`DefaultWorkspaceCatalog`/`DefaultWorkspaceResolver` internally. Default composition moved to the
new `WorkspaceResolverFactory.makeDefault(workspaceRoot:workspaceStore:workspaceCreator:)`. Added
`TimelineManagerWorkspaceResolverContractTests` proving a custom resolver (no default
catalog/factory involved) drives full timeline lifecycle/hydration. All Sources/Tests/docs/examples
references to the old names migrated; CHANGELOG updated under Unreleased. `swift build` clean,
`swift test` 950/950 passing (163 suites). **Not yet merged to PositronicKit `main`** — this is
Track 2 of the parallel PKV3 batch; integration happens via PKV3-006 after all three tracks close.

## Summary

Preserve user-extensible workspace behavior while renaming distinct persistence, catalog, factory, and resolution roles and injecting the resolver directly into TimelineManager.

## Current Problem

- `WorkspaceProtocol`, `WorkspaceCreating`, `WorkspacePersistenceProtocol`, `AgentWorkspaceService`, and `WorkspaceManager` name overlapping but distinct responsibilities.
- `TimelineManager.swift` constructs `AgentWorkspaceService → WorkspaceManager` internally, leaking default composition into orchestration.

## Implementation Requirements

- Rename to `Workspace`, `WorkspaceFactory`, `WorkspaceStore`, `WorkspaceCatalog`, and `WorkspaceResolver`.
- Make TimelineManager consume `any WorkspaceResolver` directly.
- Move default catalog/factory/resolver composition to `PositronicKit.Configuration` or a composition factory.
- Keep workspace behavior user-implementable; add a contract test with a custom resolver.
- Migrate all consumers, docs, examples, tests, and references.

## Acceptance Criteria

- [ ] A custom WorkspaceResolver supports TimelineManager without default catalog/factory internals.
- [ ] No `AgentWorkspaceService`, `WorkspaceManager`, `WorkspaceCreating`, or old persistence protocol public names remain.
- [ ] Timeline lifecycle and attachment behavior is unchanged.
- [ ] Package and local-override consumer gates pass.

