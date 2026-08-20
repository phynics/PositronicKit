# PositronicKit Architecture

PositronicKit is built on a modular, asynchronous processing architecture designed for scalability, thread safety, and clear separation of concerns.

## 1. Internal Pipeline Execution

The runtime uses a package-internal **Pipeline** implementation to sequence turn, prompt, and
context stages. It is not a consumer-facing product or extension point.

The internal pipeline provides:
1. **Sequential Execution**: Primary stages are executed one after another.
2. **Stream Merging**: The pipeline merges the `AsyncThrowingStream` from each stage into a single continuous stream for the caller.
3. **Cleanup Stages**: Stages registered via `.cleanup()` are guaranteed to run even if a primary stage fails, ensuring system integrity (e.g., closing database connections or logging final state).

## 2. Context & State Management

PositronicKit uses a dual-structure approach to state management during a pipeline execution.

### TurnContext (Immutable Snapshot)
The `TurnContext` is a thread-safe, immutable struct that represents the state of a turn at a specific point in time. It contains:
- Session-level configuration (Thread ID, Model name, maximum model rounds).
- Turn-specific data (Current messages, Available tools).
- A reference to the mutable `TurnOutputs`.

### TurnOutputs (Actor-Isolated Mutable State)
Because multiple stages might need to update the results of a turn concurrently (e.g., a streaming stage and a background tool-call extraction stage), mutable state is isolated within the `TurnOutputs` actor.
- **Thread Safety**: All mutations (appending thinking, updating usage metrics) are performed via `await` calls to the actor.
- **Safe Persistence**: At the end of the pipeline, the `TurnOutputs` are used to finalize the message state and persist it to the database.

## 3. Facade-Backed Wiring

PositronicKit is the orchestration layer. It manages the full lifecycle of an agent interaction — from resolving state, through prompt assembly and tool execution, to persisting results.

### Capability Values: The Consumer Surface

The `PositronicKit` facade is the public composition root. Use `kit.model` for raw, Thread-free
inference; `kit.threads` for Thread creation, lookup, and stateful `ThreadHandle` values;
`kit.agents` for agent identity and Thread attachment; and `kit.workspaces` for the workspace
catalog. A `ThreadHandle.send(_:)` call resolves the attached Agent and provides the managed,
Thread-addressed execution path; `sendDetached(_:)` is the explicit identity-free alternative.

Concrete managers, task registries, tool routing, `TurnEngine`, and the turn pipeline are facade
implementation details. Persistence, provider, workspace, prompt-section,
and plugin protocols remain public replaceability seams where a host owns those dependencies.

## 4. Execution Flow: The Turn Engine

The `TurnEngine` is the primary orchestrator that uses the Pipeline to handle user interactions.

1. **Initialization**: Prepares the session and initial context.
2. **ReAct Loop**: Runs a loop (`runTurnLoop`) that continues as long as the agent needs to "think" or execute tools.
3. **Pipeline Construction**: For each turn, it builds a pipeline consisting of:
   - `LLMStreamingStage`: Streams the raw response from the LLM.
   - `ToolCallExtractionStage`: Parses the stream for potential tool calls.
   - `MessagePersistenceStage`: Saves the final result once the stream completes.

## 5. Sidecar Directives (Piggy-Backed Requests)

A turn can pass `sidecars: [SidecarDirective]` to `ThreadHandle.run(...)` to request auxiliary
generations (title, summary, tone, etc.) from the *same* LLM request as the turn's response,
instead of paying a separate round-trip per auxiliary task. See
[Sidecar Directives](SidecarDirectives.md) for the current contract.

- **Composition** (`SidecarSchemaComposer`): combines a `response: string` field with one
  property per directive into a single structured-output request (all required, strict),
  and appends a prompt instruction block describing each directive. This reuses the existing
  `generationStream(structuredOutput:)` path — including the synthetic-tool fallback for providers
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
- **Events**: `TurnEvent.sidecar(delta:)` streams directive observations. Committed outcomes use
  `SidecarCompletion`, including `TurnIdentity`; terminal policy can defer that completion until
  the logical send finishes.
- **Error model**: a sidecar failure never fails the turn. Already-streamed response text is
  kept; incomplete directives report `.failed` in the completion event. A model that ignores
  the schema entirely (non-JSON prose) falls back to passthrough: the whole buffer becomes the
  response and all directives report failed.
- **Persistence**: `TurnOutputs.fullResponse` accumulates only the extracted `response` text on
  sidecar turns, so `MessagePersistenceStage` persists the same shape it always has — raw JSON
  never enters thread history.
- **No-op guarantee**: `sidecars: []` (the default) takes a completely different code path in
  `LLMStreamingStage` (no extractor is constructed) and is behaviorally identical to a turn
  without the parameter.
- Concrete directives (title, summary, tone) and their per-thread scheduling policy are
  intentionally **not** defined here; downstream applications own those policies. This layer
  only provides the mechanism.

## 6. Extension Points

PositronicKit is deliberately transport-neutral: no networking, RPC, multi-process hosting, or bundled provider SDKs in the core target. The key boundaries are:

- **Persistence protocols** for threads, messages, workspaces, tools, agents, and request origins.
- **ThreadRuntimeRepository** for atomic Turn admission, append-only history, tool intent/result
  barriers, terminal outcomes, and stale-Turn recovery. PromptJournal remains outside this boundary.
- **`WorkspaceFactory` and `Workspace`** for downstream-owned workspace resolution and execution behavior. `DefaultWorkspaceCatalog` is the bundled local provisioning implementation, not a required universal workspace model.
- **`PromptSectionProviding`** and **`TurnPlugin`** for app-specific orchestration and context hooks.
- **Provider contracts in `PKContracts`** for downstream-owned LLM adapters and tool/message projections.

### v1 Extension Point Registry

These public API surfaces are the **v1 compatibility contract**: they only change across a major version. Anything not listed here (or explicitly called out as internal) may change between minor releases.

| Category | Protocol / Type | Module | Purpose |
|----------|----------------|--------|---------|
| **Tool contracts** | `Tool`, `AnyTool`, `ToolResult`, `ToolParameters`, `ToolError` | PKContracts | Define and execute tools |
| **Orchestration hooks** | `TurnPlugin`, `CompletedTurn` | PositronicKit | Post-turn processing |
| **Prompt customization** | `PromptSectionProviding`, `PromptBuildContext` | PositronicKit | Inject custom prompt sections |
| **Persistence** | `ThreadRuntimeRepository`, `MessageStoreProtocol`, `ThreadPersistenceProtocol`, `WorkspaceStore`, `WorkspaceBindingRepository`, `MemoryStoreProtocol`, `ToolPersistenceProtocol`, `AgentStoreProtocol`, `AgentTemplateStoreProtocol`, `RequestOriginStoreProtocol` | PositronicKit | Custom storage backends |
| **Key-value store** | `KeyValueStoreProtocol` | PositronicKit | Generic key-value persistence |
| **Vector search** | `VectorStoreProtocol`, `VectorStoreError` | PositronicKit | Custom vector search backends |
| **Health check** | `HealthCheckable` | PositronicKit | Service health reporting |
| **LLM providers** | `LLMStreamClient`, `LLMConfigStore`, `LLMUtilityClient` (narrow seams); `LLMGenerationRequest`, `LLMStreamResult`, `LLMStreamChunk`, etc. | PKContracts | Provider adapter contracts |
| **Structured output** | `StructuredOutputAdapter`, `PreparedStructuredOutputRequest`, `DefaultStructuredOutputAdapter` | PKContracts | Per-client structured-output preparation without global registration |
| **Provider factories** | `LLMProviderFactory`, `PKOpenAIProvider.makeClient(configuration:)`, `PKOpenRouterProvider.makeClient(configuration:)`, `PKOllamaProvider.makeClient(configuration:)`, `PKAnthropicProvider.makeClient(configuration:)` | PKContracts / provider modules | Compile-time provider client construction; no runtime provider registry |
| **Workspace** | `Workspace`, `WorkspaceFactory`, `ToolReference`, `WorkspaceToolDefinition` | PositronicKit / PKContracts | Custom workspace backends |
| **Configuration** | `LLMConfiguration`, `GenerationParameters`, `LLMProvider` | PKContracts | LLM configuration |
| **Events** | `TurnEvent`, `ToolExecutionStatus`, `Message` | PKContracts | Stream event types |
| **Sidecar directives** | `SidecarDirective`, `SidecarDelta`, `SidecarResult` (PKContracts), `SidecarError` (PositronicKit) | PKContracts / PositronicKit | Piggy-backed auxiliary generations riding a turn's response — see [Sidecar Directives](docs/SidecarDirectives.md) |
| **Pipeline** | `PipelineStage`, `PipelineError` | package-internal utility layer | Runtime implementation detail; not a public product |
| **Runtime configuration** | `RuntimeToolPolicy`, `ThreadRuntimeRepository`, `WorkspaceBindingRepository` | PositronicKit | Configure durable ownership and built-in tool installation without exposing coordinators |

`InMemory*` stores (and `PositronicKit.PersistenceConfiguration.inMemory()`) are **public prototyping/test helpers**, not extension points — convenient for prototypes and tests, but not a stability contract.

**Internal** (not part of the v1 contract): `TurnEngine`, `TurnContext`, `TurnOutputs`, `StreamedToolCall` (chat-runtime internals); `PromptAssembler`, `PromptAssemblyOptions` (prompt assembly internals); `ContextManager`, `ContextPipelineContext`, `ContextGatheringEvent` (context pipeline internals); `ParsedToolCall`, `ToolHandlingResult`, `ToolTurnResult` (tool-routing internals).
