# PKCLEAN-013 — Expose tools grouped by workspace, not just flat list + provenance tag

**Priority:** P3
**Type:** API design (small addition)
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `82e0707`) — added `TimelineToolManager.tools(inWorkspace:)`
and `toolsGroupedByWorkspace()` exposing the per-workspace tool grouping the runtime already tracks
(custom workspace tools + `.known` system tools tagged to a workspace, with resolved provenance;
provider/global tools excluded). Additive; existing `getEnabledTools()`/`getAvailableTools()`
unchanged. 2 new tests. `make verify` green (926 tests / 158 suites).

### Summary

`TimelineToolManager` (`Sources/PositronicKit/Services/Timeline/TimelineToolManager.swift`)
already tracks tools per-workspace internally: `workspaceTools` is keyed by tool id with a
`(tool, provenance)` pair, `registerWorkspace`/`unregisterWorkspace` maintain that map, and
`ToolProvenance.workspace(id:name:)` tags which workspace a tool came from.
`ToolRouter.resolveWorkspace` (`Sources/PositronicKit/Services/Tools/ToolRouter.swift:303`)
uses this to route a tool call to the correct workspace at execution time.

What's missing is a *read* API shaped the same way: `getEnabledTools()` and
`getAvailableTools()` both return a flat `[AnyTool]` with provenance as metadata. A
consumer that wants "which tools does workspace X currently expose" has to fetch the flat
list and filter by `tool.provenance` client-side — there's no `func tools(in workspaceId:
UUID) -> [AnyTool]` or `func toolsByWorkspace() -> [UUID: [AnyTool]]` on
`TimelineToolManager`.

This is a minor, additive API gap, not a design flaw — the grouping data already exists
and only needs a query method exposed.

### Implementation Requirements

- [ ] Add `func tools(inWorkspace workspaceId: UUID) -> [AnyTool]` (or equivalent) to
      `TimelineToolManager`, filtering `workspaceTools` (and, if relevant, `knownToolProvenance`
      for `.known` system tools tagged to that workspace) by workspace id.
- [ ] Consider a `func toolsGroupedByWorkspace() -> [UUID: [AnyTool]]` convenience if a
      concrete downstream consumer (check Yakamoz's inspector drawer, which surfaces
      "prompt pipeline under glass" detail) would use it — don't add it speculatively if
      no caller wants it yet.
- [ ] Unit tests: a tool registered via `registerWorkspace` for workspace A is returned by
      the new query for A and not B; a `.known` system tool tagged to a workspace shows up
      correctly with provenance intact.

### Acceptance Criteria

- [ ] New query method(s) on `TimelineToolManager`, tested.
- [ ] No change to existing `getEnabledTools()`/`getAvailableTools()` behavior.
- [ ] `make verify` green; CHANGELOG updated if this is a public API addition.
