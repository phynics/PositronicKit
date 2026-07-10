# PositronicKit Architecture

PositronicKit is built on a modular, asynchronous processing architecture designed for scalability, thread safety, and clear separation of concerns.

## 1. The Pipeline Pattern

The core processing logic in PositronicKit follows a generic **Pipeline** pattern. This allows for complex workflows (like a chat turn) to be broken down into discrete, reusable stages.

### PipelineStage Protocol
A stage is any type that conforms to the `PipelineStage` protocol:
```swift
public protocol PipelineStage<Context, Event>: Sendable {
    associatedtype Context: Sendable
    associatedtype Event: Sendable

    var id: String { get }
    func process(_ context: Context) async throws -> AsyncThrowingStream<Event, Error>
}
```

### Pipeline Execution
The `Pipeline` class orchestrates the execution of these stages:
1. **Sequential Execution**: Primary stages are executed one after another.
2. **Stream Merging**: The pipeline merges the `AsyncThrowingStream` from each stage into a single continuous stream for the caller.
3. **Cleanup Stages**: Stages registered via `.cleanup()` are guaranteed to run even if a primary stage fails, ensuring system integrity (e.g., closing database connections or logging final state).

## 2. Context & State Management

PositronicKit uses a dual-structure approach to state management during a pipeline execution.

### ChatTurnContext (Immutable Snapshot)
The `ChatTurnContext` is a thread-safe, immutable struct that represents the state of a chat turn at a specific point in time. It contains:
- Session-level configuration (Timeline ID, Model name, Max turns).
- Turn-specific data (Current messages, Available tools).
- A reference to the mutable `TurnOutputs`.

### TurnOutputs (Actor-Isolated Mutable State)
Because multiple stages might need to update the results of a turn concurrently (e.g., a streaming stage and a background tool-call extraction stage), mutable state is isolated within the `TurnOutputs` actor.
- **Thread Safety**: All mutations (appending thinking, updating usage metrics) are performed via `await` calls to the actor.
- **Safe Persistence**: At the end of the pipeline, the `TurnOutputs` are used to finalize the message state and persist it to the database.

## 3. Facade-Backed Wiring

PositronicKit is the orchestration layer. It manages the full lifecycle of an agent interaction — from resolving state, through prompt assembly and tool execution, to persisting results.

### Two Ways In: Facade (Primary) vs. Direct Seams (Advanced)

- **The `PositronicKit` facade is the primary entry point.** Construct it, call `run(...)`, and consume the streamed `ChatEvent`s. It wires the runtime internally; most consumers never touch the underlying coordinators.
- **Advanced hosts may compose the public runtime seams directly.** When you own a server or a custom composition root, construct and hold `TimelineManager`, `ToolRouter`, and the persistence/workspace protocols yourself, or inject them into the facade via the grouped `runtime:` / `persistence:` initializers. This is a supported tier — not a private API — but you opt into more wiring in exchange for more control.

Prefer the facade unless you specifically need a seam it doesn't surface. The chat-loop internals (`ChatEngine`, the turn pipeline, prompt-assembly internals) remain implementation details either way.

## 4. Execution Flow: The Chat Engine

The `ChatEngine` is the primary orchestrator that uses the Pipeline to handle user interactions.

1. **Initialization**: Prepares the session and initial context.
2. **ReAct Loop**: Runs a loop (`runChatLoop`) that continues as long as the agent needs to "think" or execute tools.
3. **Pipeline Construction**: For each turn, it builds a pipeline consisting of:
   - `LLMStreamingStage`: Streams the raw response from the LLM.
   - `ToolCallExtractionStage`: Parses the stream for potential tool calls.
   - `MessagePersistenceStage`: Saves the final result once the stream completes.

## 5. Sidecar Directives (Piggy-Backed Requests)

A turn can pass `sidecars: [SidecarDirective]` to `PositronicKit.run(...)` to request auxiliary
generations (title, summary, tone, etc.) from the *same* LLM request as the turn's response,
instead of paying a separate round-trip per auxiliary task. Full design:
`workflow/Yakamoz/specs/2026-07-03-piggybacked-requests-design.md`.

- **Composition** (`SidecarSchemaComposer`): combines a `response: string` field with one
  property per directive into a single structured-output request (all required, strict),
  and appends a prompt instruction block describing each directive. This reuses the existing
  `chatStream(structuredOutput:)` path — including the synthetic-tool fallback for providers
  without native JSON-schema support — so sidecars need no new provider-adapter code.
  **Note:** field declaration order does *not* control model generation order — `Schema`
  stores properties in an unordered `Dictionary` and the wire path re-serializes them
  alphabetically (see ticket SDC-7). Generation order is steered only through the instruction
  block text, not schema structure.
- **Extraction** (`SidecarStreamExtractor`, driven from `LLMStreamingStage`): a synchronous
  state machine that re-parses the raw JSON buffer per content delta (via PartialJSON), diffs
  the `response` field to emit ordinary `.generation` deltas (raw JSON never reaches
  consumers), and emits directive fields as `.sidecar` deltas (buffered or incremental per
  directive) once each field completes.
- **Events**: `ChatEvent.sidecar(delta:)` for streaming updates, `ChatEvent.sidecarsCompleted(results:)`
  for terminal per-directive outcomes (`.value`, `.declined` for an explicit `null`, or
  `.failed(reason:)`).
- **Error model**: a sidecar failure never fails the turn. Already-streamed response text is
  kept; incomplete directives report `.failed` in the completion event. A model that ignores
  the schema entirely (non-JSON prose) falls back to passthrough: the whole buffer becomes the
  response and all directives report failed.
- **Persistence**: `TurnOutputs.fullResponse` accumulates only the extracted `response` text on
  sidecar turns, so `MessagePersistenceStage` persists the same shape it always has — raw JSON
  never enters conversation history.
- **No-op guarantee**: `sidecars: []` (the default) takes a completely different code path in
  `LLMStreamingStage` (no extractor is constructed) and is behaviorally identical to a turn
  without the parameter.
- Concrete directives (title, summary, tone) and their per-conversation scheduling policy are
  intentionally **not** defined here — see `workflow/Yakamoz/tickets/SID-1`/`SID-2`. This layer
  only provides the mechanism.

## 6. Extension Points

PositronicKit is deliberately transport-neutral: no networking, RPC, multi-process hosting, or bundled provider SDKs in the core target. The key boundaries are:

- **Persistence protocols** for timelines, messages, workspaces, tools, agents, and request origins.
- **`WorkspaceCreating` and `WorkspaceProtocol`** for downstream-owned workspace resolution and execution behavior. `AgentWorkspaceService` is the bundled local provisioning implementation, not a required universal workspace model.
- **`PromptSectionProviding`** and **`ChatTurnPlugin`** for app-specific orchestration and context hooks.
- **Provider contracts in `PKShared`** for downstream-owned LLM adapters and tool/message projections.

### v1 Extension Point Registry

These public API surfaces are the **v1 compatibility contract**: they only change across a major version. Anything not listed here (or explicitly called out as internal) may change between minor releases.

| Category | Protocol / Type | Module | Purpose |
|----------|----------------|--------|---------|
| **Tool contracts** | `Tool`, `AnyTool`, `ToolResult`, `ToolParameters`, `ToolError` | PKShared | Define and execute tools |
| **Orchestration hooks** | `ChatTurnPlugin`, `CompletedTurn` | PositronicKit | Post-turn processing |
| **Prompt customization** | `PromptSectionProviding`, `PromptBuildContext` | PositronicKit | Inject custom prompt sections |
| **Persistence** | `MessageStoreProtocol`, `TimelinePersistenceProtocol`, `WorkspacePersistenceProtocol`, `MemoryStoreProtocol`, `ToolPersistenceProtocol`, `AgentInstanceStoreProtocol`, `AgentTemplateStoreProtocol`, `RequestOriginStoreProtocol` | PositronicKit | Custom storage backends |
| **Key-value store** | `KeyValueStoreProtocol` | PositronicKit | Generic key-value persistence |
| **Vector search** | `VectorStoreProtocol`, `VectorStoreError` | PositronicKit | Custom vector search backends |
| **Health check** | `HealthCheckable` | PositronicKit | Service health reporting |
| **LLM providers** | `LLMStreamClient`, `LLMConfigStore`, `LLMUtilityClient` (narrow seams); `LLMChatRequest`, `LLMStreamResult`, `LLMStreamChunk`, etc. | PKShared | Provider adapter contracts |
| **Structured output** | `StructuredOutputAdapter`, `PreparedStructuredOutputRequest`, `StructuredOutputAdapterRegistry`, `DefaultStructuredOutputAdapter` | PKShared | Per-provider structured-output preparation; register a custom adapter to override the built-in behavior for an `LLMProvider` |
| **Provider registration** | `PKOpenAIProvider.register()`, `PKOpenRouterProvider.register()`, `PKOllamaProvider.register()`, `PKAnthropicProvider.register()` | Provider modules | Provider factory registration |
| **Workspace** | `WorkspaceProtocol`, `WorkspaceCreating`, `ToolReference`, `WorkspaceToolDefinition` | PositronicKit / PKShared | Custom workspace backends |
| **Configuration** | `LLMConfiguration`, `GenerationParameters`, `LLMProvider` | PKShared | LLM configuration |
| **Events** | `ChatEvent`, `ToolExecutionStatus`, `Message` | PKShared | Stream event types |
| **Sidecar directives** | `SidecarDirective`, `SidecarDelta`, `SidecarResult` (PKShared), `SidecarError` (PositronicKit) | PKShared / PositronicKit | Piggy-backed auxiliary generations riding a turn's response — see [Sidecar Directives](docs/SidecarDirectives.md) |
| **Pipeline** | `PipelineStage`, `PipelineError` | PKShared | Custom pipeline stages (advanced) |
| **Runtime coordinators (advanced)** | `TimelineManager`, `ToolRouter`, `ToolExecutionOutcome`, `RuntimeToolPolicy` | PositronicKit | Direct runtime seams for hosts with their own composition root |

`InMemory*` stores (and `PositronicKit.PersistenceConfiguration.inMemory()`) are **public prototyping/test helpers**, not extension points — convenient for prototypes and tests, but not a stability contract.

**Internal** (not part of the v1 contract): `ChatEngine`, `ChatTurnContext`, `TurnOutputs`, `StreamedToolCall` (chat-runtime internals); `PromptAssembler`, `PromptAssemblyOptions` (prompt assembly internals); `ContextManager`, `ContextPipelineContext`, `ContextGatheringEvent` (context pipeline internals); `ParsedToolCall`, `ToolHandlingResult`, `ToolTurnResult` (tool-routing internals).
