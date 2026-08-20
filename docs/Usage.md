# PositronicKit Usage Guide

This guide provides step-by-step examples for integrating `PositronicKit` and managing `Agent` within your application.

## 1. Managing Agents

`Agent` represents a live agent with its own workspace and private Thread. You manage agents
through the facade's `agents` capability.

### Creating an Agent

To create a new agent, use `kit.agents.create`. You can optionally seed it from an `AgentTemplate`.

```swift
import PositronicKit
import PKContracts

let kit = PositronicKit(languageModel: myLLM)

// Create a new agent
let agent = try await kit.agents.create(
    name: "Research Assistant",
    description: "An agent specialized in technical research."
)

let thread = try await kit.threads.create(title: "Research")
try await kit.agents.attach(agent.id, to: thread.id)
print("Created agent with ID: \(agent.id)")
```

### Attaching an Agent to a Thread

To use an agent in a specific chat thread, you must "attach" it. This grants the agent exclusive access to that thread.

```swift
let threadID = thread.id
try await kit.agents.attach(agent.id, to: threadID)
```

## 2. Initialization and Execution

The snippets below mirror functions in the `PositronicKitExamples` target, which compiles
them as part of `make verify-examples` (a step of `make verify`) — so the canonical
construction, run, and event-handling shapes here are type-checked against the current API.

### Simplified Initialization (Prototyping)

The facade's prototyping initializer takes a `languageModel` and defaults every store to
in-memory. Construct a provider-backed `LanguageModel` from your provider's configuration,
wrap it in an `LLMService`, then hand it to `PositronicKit`.

```swift
import PositronicKit
import PKContracts
import PKOpenAIProvider

// OpenAI: configure the provider, build its client, and wrap it as a LanguageModel.
var openAIConfig = ProviderConfiguration.makeDefault(for: .openAI)
openAIConfig.apiKey = "sk-..."
let configuration = LLMConfiguration(activeProvider: .openAI, providers: [.openAI: openAIConfig])
let client = PKOpenAIProvider.makeClient(configuration: configuration)
let languageModel = LLMService(
    storage: InMemoryConfigurationService(config: configuration),
    client: client,
    utilityClient: client,
    fastClient: client
)
let chat = PositronicKit(languageModel: languageModel)
```

For Ollama, use `PKOllamaProvider` and `ProviderConfiguration.makeDefault(for: .ollama)`:

```swift
import PositronicKit
import PKContracts
import PKOllamaProvider

var ollamaConfig = ProviderConfiguration.makeDefault(for: .ollama)
ollamaConfig.modelName = "llama3"
let configuration = LLMConfiguration(activeProvider: .ollama, providers: [.ollama: ollamaConfig])
let client = PKOllamaProvider.makeClient(configuration: configuration)
let languageModel = LLMService(
    storage: InMemoryConfigurationService(config: configuration),
    client: client,
    utilityClient: client,
    fastClient: client
)
let chat = PositronicKit(languageModel: languageModel)
```

The core facade stays provider-neutral: provider clients are built in their provider module
and wrapped in an `LLMService` before being passed to `PositronicKit`.

### Full Initialization (Production)

For production, assemble a `PositronicKit.Configuration` and construct via
`PositronicKit(configuration:)`. Every store in `PersistenceConfiguration` is optional and
defaults to in-memory, so provide only the durable stores your host needs.

```swift
import PositronicKit
import PKContracts

let chat = PositronicKit(configuration: .init(
    provider: .init(
        languageModel: myLLM,
        embeddingService: myEmbeddingService
    ),
    persistence: .init(
        messageStore: myMessageStore,
        threadPersistence: myThreadPersistence,
        workspacePersistence: myWorkspacePersistence,
        memoryStore: myMemoryStore,
        toolPersistence: myToolPersistence,
        agentStore: myAgentStore,
        requestOriginStore: myRequestOriginStore
    ),
    runtime: .init(
        workspaceCreator: myWorkspaceCreator
    )
))
```

### Running a Generation Stream

The `ThreadHandle.run` method takes a `TurnRequest` addressed to its Thread and returns an `AsyncThrowingStream<TurnEvent, Error>`,
so you can process real-time updates as the agent reasons and responds.

```swift
import PositronicKit
import PKContracts

// `chat` is the PositronicKit instance from the initialization example above.
let stream = try await chat.threads.open(threadID).run(TurnRequest(
    threadID: threadID,
    message: "What are the latest trends in Swift concurrency?",
))

for try await event in stream {
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
            // Only emitted on turns passed `sidecars:` — see docs/SidecarDirectives.md.
            print("\n[\(delta.name)] \(delta.partialText)")
        }

    case .meta(let event):
        switch event {
        case .generationContext(let metadata):
            print("\nContext: \(metadata.files.count) files referenced")
        default:
            // `.meta(.generationCompleted)` is deprecated and never emitted in production.
            break
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
            // Only emitted on turns passed `sidecars:` — see docs/SidecarDirectives.md.
            for result in completion.results {
                print("\n[\(result.name)] \(result.outcome)")
            }
        default:
            // `.completion(.streamCompleted)` is deprecated and never emitted in production.
            break
        }

    case .error(let event):
        switch event {
        case .toolCallError(let toolCallId, let name, let error):
            print("\nTool call error [\(toolCallId)] for \(name): \(error)")
        case .error(let message, let identity):
            print("\nError: \(message) (blocked: \(identity?.isBlocked ?? false))")
        case .generationCancelled:
            print("\nGeneration cancelled.")
        }
    }
}
```

### Enabling Prompt Assembly Logs

The runtime emits prompt-assembly diagnostics through `swift-log`. `PromptAssembler` and
`PromptAssemblyOptions` are internal runtime types, so you don't call them directly — instead pass a
`Logger` as `TurnRequest(promptAssemblyLogger:)` to enable diagnostics for that turn.

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
let events = try await chat.threads.open(threadID).run(TurnRequest(
    threadID: threadID,
    message: "…",
    promptAssemblyLogger: logger
))
```

### Handling Tool Outputs

If the agent calls a tool that requires host-side execution (e.g., a local file system tool not handled by the runtime), you can submit the outputs in a follow-up turn.

```swift
let toolOutputs = [
    ToolOutputSubmission(toolCallID: "call_123", output: "File contents...")
]

let stream = try await chat.threads.open(threadID).run(TurnRequest(
    threadID: threadID,
    message: "", // Empty message as we're continuing from a tool call
    tools: tools,
    toolOutputs: toolOutputs
))
```

## 3. Core Concepts

### TurnEvent Stream
The stream provides a rich set of events:
- `.delta(.reasoning)` and `.delta(.generation)` for streaming text.
- `.delta(.toolCall)` and `.delta(.toolExecution)` for tool progress.
- `.delta(.sidecar)` and `.completion(.sidecarsCompleted)` for piggy-backed directive results on
  turns passed `sidecars:` (see [Sidecar Directives](SidecarDirectives.md)).
- `.meta(.generationContext)` for retrieved context metadata.
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
  cancellation handling. A turn failure surfaces as a thrown error on the stream (the throw is
  that path's terminal signal); a direct cancellation emits `.generationCancelled`.

The deprecated `.meta(.generationCompleted)` and `.completion(.streamCompleted)` cases are
retained for `Codable` backward compatibility but are never emitted in production — switch on
the cases above instead.

### Agent Persistence
Agents are persistent. Their workspace (`primaryWorkspaceId`) contains their long-term memory, while their private thread (`privateThreadId`) stores their internal monologue and history.

## 4. Local Embeddings

`PKLocalEmbeddings` keeps the local embedding facade separate from the runtime core. The MiniLM backend is fully in-process: it has no provider or daemon fallback and accepts only host-provisioned model assets.

```swift
import PKLocalEmbeddings

// Apple default: Natural Language backend.
let appleDefault = LocalEmbeddingService()

// Linux: host-provisioned MiniLM assets in an explicit model directory.
let linux = try LocalEmbeddingService(miniLMModelDirectory: URL(fileURLWithPath: "/path/to/model"))

// Apple MiniLM: opt in with the MiniLMEmbeddings trait.
let appleMiniLM = try LocalEmbeddingService(miniLMModelDirectory: URL(fileURLWithPath: "/path/to/model"))
```

The Apple MiniLM path is built with the `MiniLMEmbeddings` trait (`swift test --traits MiniLMEmbeddings`); default Apple builds neither build nor link PKFastEmbed. Native setup is bootstrapped with `native/pkfastembed/bootstrap.sh --prefix <path>`, then discovered through `PKG_CONFIG_PATH`.

The pinned assets are `config.json`, `model.onnx`, `special_tokens_map.json`, `tokenizer.json`, `tokenizer_config.json`, and `vocab.txt` from `Qdrant/all-MiniLM-L6-v2-onnx` revision `5f1b8cd78bc4fb444dd171e59b18f3a3af89a079`. Exact checksums live in `native/pkfastembed/model-assets.sha256`; the host application owns fetching, verification, the model directory, and cache lifecycle.

Natural Language and MiniLM vectors are not interchangeable and must not share an index. When moving content across backends or platforms, rebuild embeddings on the destination platform.
