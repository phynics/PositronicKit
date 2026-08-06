# PKPOST-004: Group tools by workspace — workspaces as the tool-providing context

**Priority:** P3 (post-v1 architecture refinement; user direction 2026-07-05)
**Type:** Design + refactor (public API shape — semver-relevant)
**Depends on:** PKREL-004 (released line; this likely lands in a minor/major per PKPOST-002 cadence)
**Blocks:** None
**Triage:** ready-for-human
**Status:** Done (2026-07-06) — closed with 004c.

**Resolution:** Spec implemented across PKPOST-004a/b/c. `ToolProvenance`,
`ToolProviding`, and runtime assembly landed in PositronicKit `72ec444`; consumer
migration (Monad `c69bdf2`, Yakamoz `e32ba28`) and `1.1.0` release completed the
batch.
[`workflow/PositronicKit/specs/2026-07-05-workspace-scoped-tools.md`](../specs/2026-07-05-workspace-scoped-tools.md)
(grounded in consumer greps: Monad is the only `WorkspaceProtocol.listTools/executeTool`
user and only as an HTTP/RPC projection; Shuttle uses neither surface; Yakamoz hand-builds
the flat list in `resolveTools`). Decisions: D1 `ToolProviding` assembly, D2 structural
`ToolProvenance` enum, D3 delete `workspaceID` schema params, D4 minor-release migration.
Decomposed into PKPOST-004a (provenance type) → 004b (drop workspaceID args) → 004c
(`ToolProviding` assembly + consumer migration, release-triggering). This umbrella ticket
closes when 004c does.

### Summary

Tools should be **grouped by workspace**: a workspace is (for the most part) the context in
which tools exist. Today that relationship is implicit and reconstructed downstream —
PositronicKit hands the chat loop a flat `[AnyTool]` (`ToolRouter.processToolCalls(...
availableTools: [AnyTool] ...)`), `WorkspaceProtocol` has its own parallel
`listTools()`/`executeTool(id:parameters:)` surface that the flat path doesn't use, and
consumers re-derive the grouping with ad-hoc flags (Yakamoz's
`ConversationToolOption.requiresWorkspace`/`requiresTerminal` filtering in `resolveTools`,
plus per-tool `workspaceID` parameters threaded through call arguments). Make the grouping
first-class in PositronicKit instead.

### Design direction (to be specced before implementation)

- **Workspaces are tool providers.** The runtime assembles a turn's tool set from the
  conversation's attached workspaces (each contributing its tools, already confined to that
  workspace) plus explicitly-registered global/built-in tools (calculator, date/time —
  tools that genuinely exist outside any workspace, the "for the most part" carve-out).
- **Provenance:** every resolved tool knows its owning workspace (id/reference) — `AnyTool`
  already carries a `provenance` (see TEX-1's decorator preserving it); extend/formalize so
  UI can group tool listings by workspace and transcripts/inspectors can attribute a call to
  its workspace without parsing arguments.
- **Execution routes to the owner:** a workspace-provided tool executes against its owning
  workspace by construction — eliminating the `workspaceID`-as-parameter pattern (the model
  currently has to *pass* the workspace id as a tool argument, which is noise in the schema,
  a misroute risk, and exactly the kind of context that should be structural, not
  prompt-carried).
- **Reconcile the two surfaces:** either the flat-`[AnyTool]` path learns workspace
  grouping, or `WorkspaceProtocol.listTools/executeTool` becomes the canonical provider
  surface the router consumes — pick one; don't keep both half-used. (Check what Shuttle
  and Monad actually use of each today before deciding.)
- Downstream wins: Yakamoz's Compose-pane tool grouping (Built-in/Workspace/Terminal
  sections) reads straight off provenance instead of flag filtering; approval policies
  (YAK-47-style read-only acceptance) can be expressed per workspace.

### Implementation Requirements

1. Write a short spec first (`workflow/PositronicKit/specs/`) settling: provider surface,
   provenance shape, global-tool registration, migration for existing consumers — then
   decompose into implementation tickets if the spec exceeds one ticket's scope.
2. Public API changes follow the downstream-sync checklist (Monad, Shuttle, Yakamoz greps +
   compile checks) and the PKPOST-002 release cadence; keep `PositronicKitExamples` current.
3. Tests: tool-set assembly from multiple workspaces, provenance attribution, execution
   routing to the owning workspace, global tools unaffected, and schema no longer requiring
   workspace-id parameters for workspace tools.

### Acceptance Criteria

- [ ] Spec agreed (provider surface + provenance + migration).
- [ ] A turn's tools are assembled per-workspace with structural provenance; workspace
      tools execute against their owner without id-as-argument.
- [ ] Exactly one canonical tool-provision surface remains.
- [ ] All three consumers compile and their gates pass on the repinned release; Yakamoz
      tool grouping consumes provenance.
- [ ] `make verify` green.
