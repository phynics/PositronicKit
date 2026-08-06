# PKAPI-002 — `Tool.id`/`Tool.name` to `LLMToolDefinition.name` mapping is non-obvious

**Priority:** P3
**Type:** API design / naming
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (commit `3c2cf33`, 2026-07-10)

> **Resolution:** Renamed `Tool.id` → `Tool.callName` across all PositronicKit
> conformers (7 filesystem tools, 3 timeline tools, `AnyTool`, `WorkspaceToolWrapper`,
> `ExampleGreetingTool`) and all call sites (ToolRouter, TimelineToolManager,
> ToolContext, ToolTimelineContext, MessagePersistenceStage, FoundationModelsToolBridge,
> Tool+OpenAI, WorkspaceToolDefinition+Extensions). 20+ test files migrated. Doc
> comment updated to clarify the wire role (`LLMToolDefinition.name`). Downstream
> consumers (Monad/Shuttle/Yakamoz) with custom `Tool` conformers need to rename
> `var id` → `var callName` on their next PositronicKit pin bump.

> **Decision 2026-07-10 (user):** rename `Tool.id` → `callName` to signal its wire role.
> Collapsing `id`/`name` into one field is **rejected** — `ToolAPIController.swift:68` exposes
> `id` and `name` separately over HTTP (`ToolInfo(id: $0.id, name: $0.name, …)`), so the display
> name is load-bearing. Breaking public API: grep every `Tool`/`AnyTool` conformer across
> Monad/Shuttle/Yakamoz and migrate in the same change; update CHANGELOG.

### Summary

Confirmed: `Tool.id` is documented as "the identifier the LLM uses to call it" and
`Tool.name` as "human-readable display name" (`Sources/PKShared/Tools/Tool.swift:49-53`).
But `LLMToolDefinition` — the actual wire type sent to providers
(`Sources/PKShared/SharedTypes/LLMProviderContracts.swift:5-9`) — has only one field,
`name: String`, which is populated from `Tool.id`. `Tool.name` (the display name) never
reaches the wire. A reader cannot infer this mapping from the types alone; `id` reads as
"internal identifier," not "the LLM-facing function name," which is what it actually is.

### Implementation Requirements

- [ ] Find every call site that constructs `LLMToolDefinition` from a `Tool`/`AnyTool` and
      confirm `id` (not `name`) is what's threaded through (spot-checked in `Tool.swift`
      but confirm the provider-adapter request-building code too).
- [ ] Decide the fix: (a) rename `Tool.id` to something that signals "this is the LLM
      function-call name" (e.g. `callName`), or (b) collapse `id`/`name` into one field if
      the display-name use case turns out to be unused/redundant — check whether any
      consumer (Yakamoz's tool UI, MonadCLI) actually reads `Tool.name` for display
      separately from `id` before collapsing.
- [ ] If renaming, this is a public API change — downstream grep across
      Monad/Shuttle/Yakamoz for all custom `Tool` conformers before landing.

### Acceptance Criteria

- [ ] Either `Tool.id` is renamed to signal its wire role, or the doc comment on `Tool.id`
      explicitly states "this becomes `LLMToolDefinition.name`" so the mapping isn't
      left to inference.
- [ ] `make verify` green; CHANGELOG updated if renamed.
