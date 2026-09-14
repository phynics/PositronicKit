# PositronicKit Usage Guide

This guide documents the unreleased Next / v5 runtime. For production, start from the
[stable tagged README](https://github.com/phynics/PositronicKit/blob/5.1.0/README.md).

## 1. Managing Agents

`Agent` is persistent identity, instructions, and continuity. Every Agent owns one primary Timeline
and primary Workspace, can participate in many ordinary Timelines, and is not independently callable.
Each Timeline attaches at most one Agent. Manage Agents through the facade's `agents` capability.

### Creating an Agent

To create a new agent, use `kit.agents.create`. You can optionally seed it from an `AgentTemplate`.

```swift
import PositronicKit
import PKContracts

let kit = PKRuntime(languageModel: myLLM)

// Create a new agent
let agent = try await kit.agents.create(
    name: "Research Assistant",
    description: "An agent specialized in technical research."
)

let timeline = try await kit.timelines.create(
    title: "Research",
    attaching: agent.id
)
print("Created agent with ID: \(agent.id)")
```

### Attaching an Agent to a Timeline

Attach an Agent when a Timeline should run managed Turns under that identity. The attachment is
exclusive from the Timeline's perspective: a Timeline has zero or one Agent, while an Agent may be
attached to many Timelines.

```swift
let timelineID = timeline.id
try await kit.agents.attach(agent.id, to: timelineID)
```

Managed Turns capture one immutable `AgentContextSnapshot` at admission. The default source
reads the Agent primary Workspace's root `SOUL.md` as instructions and catalogs other Markdown notes
for on-demand reading; applications with database, remote, or no-memory continuity can inject an
`AgentContextSource` through `RuntimeConfiguration`.

Agent lifecycle is explicit. `kit.agents.retire(agent.id)` stops new managed Turns, waits for
admitted Turns to finish, detaches ordinary Timelines, and archives the Agent's primary Timeline.
Call `kit.agents.purge(agent.id)` only after retirement when the host's retention policy permits
removing the Agent and its owned resources.

## 2. Initialization and Execution

The snippets below mirror functions in the `PositronicKitExamples` target, which compiles
them as part of `make verify-examples` (a step of `make verify`) — so the canonical
construction, run, and event-handling shapes here are type-checked against the current API.

### Simplified Initialization (Prototyping)

Provider packages expose a configured-provider factory for the common path. It creates the client
and configuration once, while `PKRuntime` keeps service assembly internal.

```swift
import PositronicKit
import PKOpenAIProvider

let provider = PKOpenAI.makeConfiguredProvider(
    apiKey: "sk-...",
    model: "gpt-4o"
)
let kit = PKRuntime(provider: provider)
```

For Ollama, use the provider factory without an API key:

```swift
import PositronicKit
import PKOllamaProvider

let provider = PKOllama.makeConfiguredProvider(model: "llama3")
let kit = PKRuntime(provider: provider)
```

OpenRouter and Anthropic use the same configured-provider pattern. Foundation Models is the
documented exception: it has no API key, endpoint, or network model selection, so pass a
`FoundationModelsClient` through `PKRuntime(languageModel:)` instead.

### Full Initialization (Production)

For production, assemble a `PKRuntime.Configuration` and construct via
`PKRuntime(configuration:)`. The runtime repository is required because it atomically owns
Timeline history and Turn transitions; the remaining stores may use in-memory defaults for local
development.

```swift
import PositronicKit
import PKContracts

let kit = PKRuntime(configuration: .init(
    languageModel: streamClient,
    persistence: .init(
        runtimeRepository: myRuntimeRepository,
        workspacePersistence: myWorkspacePersistence,
        toolPersistence: myToolPersistence,
        agentStore: myAgentStore,
        requestOriginStore: myRequestOriginStore
    ),
    runtime: .init(
        workspaceProfile: .hostManaged(root: myWorkspaceRoot),
        workspaceCreator: myWorkspaceCreator
    )
))
```

### Running a Generation Stream

The managed `TimelineHandle.startTurn` method captures the Agent attached to its Timeline and returns
a `TurnHandle`. Its `events()` stream is nonthrowing, while `outcome()` returns the same durable
terminal result for every joiner.

```swift
import PositronicKit
import PKContracts

// `kit` is the PKRuntime instance from the initialization example above.
let turn = try await kit.timelines.open(timelineID).startTurn(
    "What are the latest trends in Swift concurrency?",
    options: TurnOptions(generationParameters: GenerationParameters(temperature: 0.2))
)
let stream = turn.events()

for await event in stream {
    switch event {
    case .delta(let event):
        switch event {
        case .reasoning(let text):
            print("\nThinking: \(text)", terminator: "")
        case .generation(let text):
            print(text, terminator: "")
        case .toolCall(let delta):
            print("\nTool delta: \(delta.name ?? "<continuation>")")
        case .toolExecution(let toolCallId, let status):
            print("\nTool execution [\(toolCallId)]: \(status)")
        case .sidecar(let delta):
            // Only emitted on turns passed `TurnOptions(sidecars:)` — see docs/SidecarDirectives.md.
            print("\n[\(delta.name)] \(delta.partialText)")
        }

    case .completion(let event):
        switch event {
        case .generationCompleted(let message, _):
            print("\nDone: \(message.content)")
        case .completedEmpty(let finishReason):
            print("\nCompleted empty (finishReason: \(finishReason ?? "nil"))")
        case .toolExecution(let toolCallId, let status):
            print("\nTool completed [\(toolCallId)]: \(status)")
        case .maxModelRoundsReached:
            print("\nMaximum model rounds reached — the agent did not produce a tool-free final response.")
        case .deferredForExternalTool:
            print("\nTool calls deferred for external execution; stream paused for host-side work.")
        case .sidecarsCompleted(let completion):
            // Only emitted on turns passed `TurnOptions(sidecars:)` — see docs/SidecarDirectives.md.
            for result in completion.results {
                print("\n[\(result.name)] \(result.outcome)")
            }
        }

    case .error(let event):
        switch event {
        case .toolCallError(let toolCallId, let name, let error):
            print("\nTool call error [\(toolCallId)] for \(name): \(error)")
        case .error(let message, let identity):
            print("\nError: \(message) (blocked: \(identity?.isBlocked ?? false))")
        case .durabilityFailure(let message, let identity):
            print("\nDurability failure: \(message) (identity: \(String(describing: identity)))")
        case .generationCancelled:
            print("\nGeneration cancelled.")
        }
    }
}
```

### Streaming generated text and awaiting one result

The common path needs no nested event switch. `generatedText()` streams assistant
text fragments in order, and `result()` awaits one consolidated, durable
`TurnResult` with the terminal `outcome` and the final assistant `message` when
the Turn recorded one:

```swift
let turn = try await kit.timelines.open(timelineID).startTurn("Summarize the timeline.")

for await text in turn.generatedText() {
    render(text)
}

let result = try await turn.result()
print(result.message?.content ?? "")
```

- `generatedText()` and `events()` are alternative views over one shared stream:
  consume the Turn through one of them, not both concurrently. The full event
  stream stays available for advanced consumers.
- `result()` reads the atomic Timeline runtime repository after the Turn is
  terminal, so every joiner observes the same durable result — including
  joiners that never consumed the stream. Distinguish empty, deferred,
  cancelled, and failed Turns via `result.outcome`, not via message presence:
  deferred Turns are `.interrupted` with no message, while empty output keeps
  its (empty) assistant row under `.completed`.
- Cancelling the task that awaits `result()` throws `CancellationError` without
  recording an outcome; a bounded wait that elapses first throws
  `TurnOutcomeTimedOut`. Neither is a durable outcome — the Turn may still be
  running. Abandoning `generatedText()` follows the same owner-only
  cancellation rule as abandoning `events()`.

### Running a direct Turn

Use a detached Timeline for direct execution. `DirectTurnContext` uses the conventional `.host`
contributor when you omit `contributors`.

```swift
import PositronicKit

let timeline = try await kit.timelines.create(title: "Scratchpad")
let turn = try await timeline.startDirectTurn(
    "Continue the summary.",
    context: DirectTurnContext(systemInstructions: "")
)
```

Pass an explicit contributor array when a `TurnContextSource` needs a different selection.

### Reading Timeline history

Read durable messages through `kit.timelines.messages(for:)`. The result is ordered from oldest to
newest by `TimelineMessage.timestamp`. Messages with equal timestamps keep their append order. An
unknown Timeline ID returns an empty array.

```swift
let history = try await kit.timelines.messages(for: timeline.id)
for message in history {
    print("\(message.messageRole): \(message.content)")
}
```

`TimelineCapability.messages(for:)` reads semantic Timeline history. It does not read the assembled
prompt state observed by `PromptJournal`.

### Typed One-Shot Structured Generation

Use `kit.model.generate` when the response should be decoded into a schema-backed Swift type
without creating or updating a Timeline.

```swift
import JSONSchemaBuilder
import PositronicKit

@Schemable
struct ProjectMetadata: Decodable, Sendable {
    let projectName: String
    let language: String

    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
        case language
    }
}

let metadata = try await kit.model.generate(
    ProjectMetadata.self,
    from: "Extract the project metadata."
)
```

The output type must be `Decodable`, `Sendable`, and `Schemable`. Its generated schema keys must
agree with its `CodingKeys` and the decoder's key strategy. A schema construction failure throws
`StructuredGenerationError.schemaConstructionFailed`. A response that remains invalid after
lenient JSON repair throws `StructuredOutputDecodingError.invalidJSONPayload`; valid JSON that
cannot decode as the requested type throws `.decodingFailed`, including custom decoder failures.
Provider, idle-timeout, and cancellation errors retain their existing identities. Use the
advanced `kit.model.generateStructured` operation when you need the raw JSON payload or a
hand-built schema; its next breaking-release rename is tracked in
[#176](https://github.com/phynics/PositronicKit/issues/176).

### Enabling Prompt Assembly Logs

The runtime emits prompt-assembly diagnostics through `swift-log`. `PromptAssembler` and
`PromptAssemblyOptions` are internal runtime types, so you don't call them directly — instead pass a
`Logger` as `TurnOptions(promptAssemblyLogger:)` to enable diagnostics for that turn.

```swift
import Logging
import PositronicKit

// Bootstrap once, early in startup, so the host owns output + level selection.
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .debug
    return handler
}

let logger = Logger(label: "com.example.prompt-assembly")
let turn = try await kit.timelines.open(timelineID).startTurn(
    "…",
    options: TurnOptions(promptAssemblyLogger: logger)
)
let events = turn.events()
```

### Handling PKTool Outputs

If the agent calls a tool that requires host-side execution (e.g., a local file system tool not handled by the runtime), you can submit the outputs in a follow-up turn.

```swift
let toolOutputs = [
    ToolOutputSubmission(toolCallID: "call_123", output: "File contents...")
]

let turn = try await kit.timelines.open(timelineID).startTurn(
    "", // Empty message as we're continuing from a tool call
    options: TurnOptions(tools: tools, toolOutputs: toolOutputs)
)
let stream = turn.events()
```

## 3. Core Concepts

### TurnEvent Stream
The stream provides a rich set of events:
- `.delta(.reasoning)` and `.delta(.generation)` for streaming text.
- `.delta(.toolCall)` and `.delta(.toolExecution)` for tool progress.
- `.delta(.sidecar)` and `.completion(.sidecarsCompleted)` for piggy-backed directive results on
  turns passed `TurnOptions(sidecars:)` (see [Sidecar Directives](SidecarDirectives.md)).
- `.completion(.generationCompleted)` for the terminal event on normal completion (one per
  completed turn; the final one closes the stream).
- `.completion(.completedEmpty)` for a successful but empty assistant response.
- `.completion(.maxModelRoundsReached)` for the terminal event when the ReAct loop exhausts its
  `maxModelRounds` budget while tool calls are still pending — distinct from normal completion so
  consumers can tell exhaustion apart from success.
- `.completion(.deferredForExternalTool)` for the terminal event when at least one tool call is
  deferred for external (host-side) execution — the stream pauses for the host to submit tool
  outputs in a follow-up turn.
- `.error(.toolCallError)`, `.error(.error)`, and `.error(.generationCancelled)` for failure and
  cancellation handling. `.error(.durabilityFailure)` identifies a terminal persistence failure.
  `TurnHandle.events()` is nonthrowing; its durable `outcome()` is the authoritative terminal
  result.

Cancelling the task that consumes `TurnHandle.events()` cancels the admitted Turn, terminates the
provider stream, and clears the Timeline's active-task registration. This applies only to the caller
that admitted the Turn: a consumer that joined or replayed a Turn another caller owns can abandon
its stream freely, and the owner's generation keeps running. A `TurnHandle` also exposes explicit
`cancel()` and can be used when cancellation should be tied to the Turn identity rather than to a
stream consumer.

### Agent Persistence
Agents are persistent. Their primary Workspace (`primaryWorkspaceID`) supplies continuity through
the configured `AgentContextSource`, while their primary Timeline (`privateTimelineID`) stores the
Agent-owned history boundary. Managed Turn preparation fails closed when a required custom context
source fails; direct Turns do not load Agent context. Other runtime integrations belong in
`RuntimeConfiguration.customization`: `TurnContextSource` contributes bounded namespaced notes,
`AgentActivitySink` receives best-effort lifecycle facts, and `TurnOutcomeSink` runs only after a
terminal outcome is durable. These integrations do not mirror Workspace activity into the Agent's
primary Timeline: tool history remains on the Timeline whose Turn executed it. Sink failures are
persisted as host-facing notices and do not change the originating outcome.

### Workspace tool dispatch

Managed and direct Turns expose one provider-facing workspace dispatcher, `call_tool`. The runtime
captures Timeline-bound Workspaces at Turn admission, and managed Turns additionally capture the Agent
primary Workspace, including each tool's label, description, and schema. A model may call `call_tool`
with `tool`, optional `at` (a Workspace UUID), and `arguments`; `at` may be omitted only when exactly
one authorized Workspace provides the requested tool. If more than one matches, the model receives
the authorized IDs and labels, tool descriptions and schemas, and an explicit corrected call. Routing
is evaluated against the admission snapshot, so Workspace attachment or catalog changes affect the
next Turn only. Direct Turns use only Timeline-bound Workspaces and never inherit Agent context.
The runtime revalidates ordinary bindings immediately before a side effect, so a released or
transferred binding fails closed.

Runtime and request-scoped tools remain separate from `call_tool`; callers cannot register a tool
with that reserved name. PKTool intent/result records and successful tool events retain the resolved
Workspace ID and whether routing was explicit or implicit, including failed and persistence-failed
events. Ambiguous matches also append a durable `ambiguousWorkspaceTool` TurnNotice for hosts.
