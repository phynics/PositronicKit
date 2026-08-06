# Workspace-scoped tools — design spec (PKPOST-004)

**Date:** 2026-07-05
**Status:** Proposed (spec only; implementation decomposed into PKPOST-004a/b/c)
**Driver:** Tools should be grouped by workspace — the workspace is (for the most part) the
context in which tools exist (user direction 2026-07-05).

## 1. Current state (grounded)

Three half-connected surfaces carry "which tools exist and where":

1. **Flat per-turn list.** `ToolRouter.processToolCalls(outputs:timelineId:availableTools:continuation:)`
   (`PositronicKit/Sources/PositronicKit/Services/Tools/ToolRouter.swift:112`) receives
   `availableTools: [AnyTool]` assembled upstream. Consumers hand-build it:
   Yakamoz's `YakamozRuntime.resolveTools(enabledToolIds:workspaceRoot:terminals:)`
   (`Yakamoz/Sources/YakamozCore/Runtime/YakamozRuntime.swift:118`) instantiates built-ins +
   filesystem tools + terminal tools, then downstream UI re-derives grouping via
   `ConversationToolOption.requiresWorkspace`/`requiresTerminal` flag filtering
   (`Yakamoz/Sources/Yakamoz/Views/Inspector/ToolsInspectorView.swift`, `ToolSettingsView`).
2. **`WorkspaceProtocol.listTools()/executeTool(id:parameters:)`**
   (`PositronicKit/Sources/PositronicKit/Models/Workspace/WorkspaceProtocol.swift:18-23`),
   returning `ToolReference`s (metadata, not executables). Used by **Monad only**, as an
   HTTP/RPC surface: `WorkspaceAPIController` routes `GET :workspaceId/tools`
   (`Monad/Sources/MonadServer/Controllers/WorkspaceAPIController.swift:32,156`),
   `RemoteWorkspace` forwards over RPC
   (`Monad/Sources/MonadServer/Models/Workspace/RemoteWorkspace.swift:25-33`), and
   `LocalWorkspace.executeTool` is a stub (`LocalWorkspace.swift:29`, ignores its
   parameters). **Shuttle uses neither.** Chat-turn execution never goes through this
   surface — the router executes `AnyTool`s directly.
3. **String provenance + id-as-argument.** `AnyTool.provenance: String?`
   (`PositronicKit/Sources/PKShared/Tools/Tool.swift:174`) is a display label interpolated
   into the prompt (`Tool.promptString(provenance:)`, `Tool.swift:104`). Actual routing
   context rides *inside the model-authored arguments*: all five filesystem tools declare a
   `workspaceID` schema property (`PKShared/Tools/Filesystem/ReadFileTool.swift:40`,
   `ListDirectoryTool.swift:39`, `FindFileTool.swift:43`, `SearchFilesTool.swift:58`,
   `SearchFileContentTool.swift:58`) that the model must copy from the prompt into every
   call — visible as noise in Yakamoz's transcript (`cat(path: …, workspaceID: 08573919-…)`)
   and a misroute risk (nothing stops the model passing the wrong id).

## 2. Decisions

### D1 — Workspaces are tool providers; the runtime assembles the turn's tool set

New protocol in `PKShared` (next to `Tool.swift`):

```swift
/// A source of executable tools scoped to one context (typically a workspace).
public protocol ToolProviding: Sendable {
    /// Structural identity of the providing context; `.global` for context-free tools.
    var toolProvenance: ToolProvenance { get }
    /// Tools this provider currently offers, already bound to their owning context.
    func provideTools() async -> [AnyTool]
}
```

`TimelineManager`/the facade assemble a turn's tools as
`globalTools + attachedWorkspaceProviders.flatMap(provideTools)` instead of accepting a
caller-flattened list. The flat `[AnyTool]` remains the router's *internal* turn input —
`ToolRouter` doesn't change — but consumers stop hand-building it.

**Why not make `WorkspaceProtocol.listTools` canonical?** It traffics in `ToolReference`
metadata, not executables; making it executable-bearing would force `AnyTool` across
Monad's RPC boundary. Monad's HTTP surface keeps `listTools` (it can be implemented as a
projection of `provideTools()`); it stops pretending to be the runtime's tool source.
`LocalWorkspace.executeTool`'s dead stub is deleted.

### D2 — Structural provenance replaces the display string

```swift
public enum ToolProvenance: Sendable, Equatable, Codable {
    case global
    case workspace(id: UUID, name: String)
    case terminal(id: UUID, name: String)   // Yakamoz terminal workspaces
}
```

`AnyTool.provenance` becomes `ToolProvenance` (default `.global`). The prompt label
(`promptString(provenance:)`, `Tool.swift:104,120,131`) renders `name` from the enum —
byte-identical prompt output for the existing workspace case. The old free-string init is
kept one release as `@available(*, deprecated)` mapping to `.workspace(id:…, name:)` where
callers can supply an id, else `.global`.

**Consumer win (Yakamoz):** Compose-pane grouping (`ToolSettingsView`'s
Built-in/Workspace/Terminal sections) switches from `requiresWorkspace`/`requiresTerminal`
flag filtering to grouping by `tool.provenance` — the flags stay only as *capability*
metadata ("needs a workspace to exist"), no longer as the grouping mechanism.

### D3 — Execution routes to the owner; `workspaceID` leaves the schemas

Workspace tools are constructed *bound* to their workspace (they already are — e.g.
`ReadFileTool` takes its root at init). The `workspaceID` schema property and its
extraction in `execute(parameters:)` are deleted from all five filesystem tools; the
before/after for `ReadFileTool`:

```swift
// BEFORE (ReadFileTool.swift:40): model must echo routing context per call
JSONProperty(key: "workspaceID") { JSONString().description("The workspace to read from") }
// AFTER: property gone; the tool instance is already scoped — path is the only parameter.
```

The prompt's path-resolution guidance (`Tool.swift:131` — "If a tool is tagged with a
workspace provenance…") is rewritten to drop the id-echo instruction. This is the
user-visible payoff: `cat(path: d12matrix/1.hash.key)` with no UUID noise, and no
misroute-by-model possible.

### D4 — Migration & compatibility

- **Semver:** `AnyTool.provenance` type change + schema changes to shipped tools ⇒ next
  **minor** at least; ship together with the deprecated bridge (per PKPOST-002 cadence).
- **Monad:** keep `WorkspaceAPIController` routes; `RemoteWorkspace` unchanged (its RPC
  surface is orthogonal). Grep confirmed no reliance on `workspaceID` tool arguments.
- **Shuttle:** no usage of either surface; only recompile.
- **Yakamoz:** `resolveTools` (`YakamozRuntime.swift:118`) becomes a set of
  `ToolProviding` conformances (folder workspace, terminal registry, built-ins) handed to
  the facade; `ConversationToolOption` grouping reads provenance. TEX-1's
  `withExplanationParameter()` and YAK-47's planned permission decorator compose unchanged
  (decorators must forward `toolProvenance` — add a test).
- **Persisted data:** tool call arguments already persisted with `workspaceID` keys remain
  readable (they're opaque JSON); no migration.

## 3. Ticket decomposition

| Ticket | Scope | Depends on |
|--------|-------|------------|
| PKPOST-004a | `ToolProvenance` enum, `AnyTool` migration + deprecated string bridge, prompt-label parity tests | — |
| PKPOST-004b | Delete `workspaceID` schema params from the 5 filesystem tools + prompt guidance rewrite; misroute regression tests | 004a |
| PKPOST-004c | `ToolProviding` + facade/TimelineManager assembly from providers + globals; delete `LocalWorkspace.executeTool` stub path; consumer migration (Yakamoz providers, Monad projection) + downstream-sync checklist | 004a, 004b |

Each lands with `make verify` + `make verify-products` green and the downstream grep gate;
004c is the release-triggering ticket (tag per PKPOST-002, consumers repin).
