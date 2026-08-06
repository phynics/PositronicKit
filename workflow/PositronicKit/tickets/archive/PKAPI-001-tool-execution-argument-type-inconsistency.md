# PKAPI-001 — Unify tool-argument type across the execution boundary; type `parametersSchema`; fix `canExecute` doc

**Priority:** P2
**Type:** API design
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `856dfb9`, merged into `main`) — `Tool.execute(parameters:)`/
`Tool.summarize(parameters:result:)` now take `[String: AnyCodable]` (Sendable), matching
`WorkspaceProtocol.executeTool`/`ToolApprovalGate.requestApproval`; `AnyTool`'s forwarding impls
and every built-in tool updated. `Tool.parametersSchema` retyped to `JSONSchema.Schema`;
`Tool.toLLMToolDefinition()` consumes it directly with no encode/decode round-trip.
`ToolParameterSchema` kept as a builder helper. `WorkspaceToolDefinition.parametersSchema` stays
`[String: AnyCodable]` (must remain `Codable`/`Hashable` for `ToolReference`); `Tool`↔DTO boundary
converts via `Schema.asDictionary`/`Schema(_:)`. `canExecute()` doc corrected (no environment
parameter exists). Downstream migration (custom `Tool` conformers in Monad/Shuttle/Yakamoz) is
deferred to their next PositronicKit pin bump per CHANGELOG note. `make verify` green.
CHANGELOG updated (Breaking).

### Summary

Three confirmed issues at the `Tool`/`WorkspaceProtocol`/`ToolApprovalGate` boundary
(`Sources/PKShared/Tools/Tool.swift`, `Sources/PositronicKit/Models/Workspace/WorkspaceProtocol.swift`,
`Sources/PKShared/Tools/ToolApprovalGate.swift`):

1. **Argument type is inconsistent.** `Tool.execute(parameters:)` and
   `Tool.summarize(parameters:result:)` take `[String: Any]` (Tool.swift:84,93,255,259),
   but `WorkspaceProtocol.executeTool(id:parameters:)` (WorkspaceProtocol.swift:22,44) and
   `ToolApprovalGate.requestApproval(tool:arguments:)` (ToolApprovalGate.swift:30) take
   `[String: AnyCodable]`. `Any` is un-Sendable and untyped; the rest of the runtime has
   standardized on `AnyCodable`. A tool implementer has to juggle both.
2. **`parametersSchema` is weakly typed.** `Tool.parametersSchema` is `[String: AnyCodable]`
   (Tool.swift:71,247) — a decoded JSON dictionary — while every other schema surface in
   the package is typed: `LLMToolDefinition.parameters: Schema?`,
   `SidecarDirective.schema: Schema`, `StructuredOutputSchema.schema: Schema`,
   `ToolParameterSchema` wraps `Schema`. Tool authors are forced into the weakest form
   while the wire types are strongly typed.
3. **`canExecute()`'s doc doesn't match its signature.** `Tool.canExecute() async -> Bool`
   (Tool.swift:67) is documented as "whether the tool is currently available for
   execution in the **given environment**" but takes no environment parameter — the doc
   describes a capability the API doesn't have.

### Implementation Requirements

- [ ] Pick one representation for tool arguments — `[String: AnyCodable]` is the existing
      majority and Sendable-safe — and change `Tool.execute`/`Tool.summarize` to match.
      Update `AnyTool` (Tool.swift:255,259) and every built-in tool implementation
      (`Sources/PKShared/Tools/Filesystem/*.swift`) accordingly.
- [ ] Change `Tool.parametersSchema` from `[String: AnyCodable]` to `Schema` (or
      `ToolParameterSchema`, whichever the existing `ToolParameterSchema` type in
      `Sources/PKShared/Tools/ToolParameterSchema.swift` is meant to be used for) and
      update all conformers plus wherever it's serialized into `LLMToolDefinition.parameters`.
- [ ] Fix `canExecute()`'s doc comment: either drop "in the given environment" or add the
      environment/context parameter if that capability is actually needed by any current
      or planned tool. Check existing conformers (`ChangeDirectoryTool`, `FindFileTool`,
      etc.) for what "environment" they actually depend on (likely just internal state,
      not an injected context) before deciding.

### Acceptance Criteria

- [ ] Single argument type across `Tool.execute`, `Tool.summarize`,
      `WorkspaceProtocol.executeTool`, `ToolApprovalGate.requestApproval`.
- [ ] `Tool.parametersSchema` is `Schema`-typed; no `[String: AnyCodable]` schema surface
      remains on the public `Tool` protocol.
- [ ] `canExecute()` doc accurately describes its signature.
- [ ] Downstream grep across Monad/Shuttle/Yakamoz for any custom `Tool` conformers.
- [ ] `make verify` green; CHANGELOG updated (breaking API change).
