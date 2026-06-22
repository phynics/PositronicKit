# PositronicKit Usage Guide

This guide provides step-by-step examples for integrating `PositronicKit` and managing `AgentInstance` within your application.

## 1. Managing Agent Instances

`AgentInstance` represents a live agent with its own workspace and private timeline. You manage these instances using the `AgentInstanceManager`.

### Creating an Instance

To create a new agent instance, use the `createInstance` method. You can optionally seed it from an `AgentTemplate`.

```swift
import PositronicKit
import PKShared

let manager = AgentInstanceManager(repository: myWorkspaceRepository)

// Create a new agent instance
let instance = try await manager.createInstance(
    from: nil, // Optional AgentTemplate
    name: "Research Assistant",
    description: "An agent specialized in technical research."
)

print("Created agent with ID: \(instance.id)")
```

### Attaching an Agent to a Timeline

To use an agent in a specific chat timeline, you must "attach" it. This grants the agent exclusive access to that timeline.

```swift
let timelineId = UUID() // Your existing timeline ID
try await manager.attach(agentId: instance.id, to: timelineId)
```

## 2. Initialization and Execution

### Simplified Initialization (Prototyping)

The easiest way to get started is by providing your OpenAI API key or an Ollama model. This uses in-memory stores for everything.

```swift
import PositronicKit
import PKOpenAIProvider
import PKOllamaProvider

// For OpenAI
let chat = PositronicKit(openAIKey: "sk-...")

// For Ollama
let chat = PositronicKit(ollamaModel: "llama3")
```

This provider-backed path keeps the convenience initializer in the matching provider module while the core facade stays provider-neutral.

### Full Initialization (Production)

For production, you should provide persistent stores through the grouped `persistence:` initializer.

```swift
import PositronicKit
import PKShared

let chat = PositronicKit(
    llmService: myLLM,
    persistence: .init(
        messageStore: myMessageStore,
        timelinePersistence: myTimelinePersistence,
        workspacePersistence: myWorkspacePersistence,
        memoryStore: myMemoryStore,
        toolPersistence: myToolPersistence,
        agentInstanceStore: myAgentInstanceStore,
        requestOriginStore: myRequestOriginStore
    ),
    embeddingService: myEmbeddingService,
    runtime: .init(
        timelineManager: myTimelineManager,
        toolRouter: myToolRouter
    )
)
```

### Running a Chat Stream

The `run` method returns an `AsyncThrowingStream<ChatEvent, Error>`. This allows you to process real-time updates as the agent "thinks" and responds.

```swift
import PositronicKit
import PKShared

let chat = PositronicKit(
    llmService: myLLM,
    persistence: .init(
        messageStore: myMessageStore,
        timelinePersistence: myTimelinePersistence,
        workspacePersistence: myWorkspacePersistence,
        memoryStore: myMemoryStore,
        toolPersistence: myToolPersistence,
        agentInstanceStore: myAgentInstanceStore,
        requestOriginStore: myRequestOriginStore
    ),
    embeddingService: myEmbeddingService,
    runtime: .init(
        timelineManager: myTimelineManager,
        toolRouter: myToolRouter
    )
)

let stream = try await chat.run(
    timelineId: timelineId,
    message: "What are the latest trends in Swift concurrency?",
    agentInstanceId: instance.id // The agent we created earlier
)

for try await event in stream {
    switch event {
    case .delta(let event):
        switch event {
        case .thinking(let text):
            print("\nThinking: \(text)", terminator: "")
        case .generation(let text):
            print(text, terminator: "")
        case .toolCall(let delta):
            print("\nTool delta: \(delta.name ?? "<continuation>")")
        case .toolExecution(let toolCallId, let status):
            print("\nTool execution [\(toolCallId)]: \(status)")
        }

    case .meta(let event):
        switch event {
        case .generationContext(let metadata):
            print("\nContext: \(metadata.files.count) files referenced")
        case .generationCompleted(let message, let metadata):
            print("\nMeta completion: \(message.content) (\(metadata.totalTokens ?? 0) tokens)")
        }

    case .completion(let event):
        switch event {
        case .generationCompleted(let message, _):
            print("\nDone: \(message.content)")
        case .toolExecution(let toolCallId, let status):
            print("\nTool completed [\(toolCallId)]: \(status)")
        case .streamCompleted:
            print("\nStream finished.")
        }

    case .error(let event):
        switch event {
        case .toolCallError(let toolCallId, let name, let error):
            print("\nTool call error [\(toolCallId)] for \(name): \(error)")
        case .error(let message):
            print("\nError: \(message)")
        case .generationCancelled:
            print("\nGeneration cancelled.")
        }
    }
}
```

### Enabling Prompt Assembly Logs

The runtime emits prompt-assembly diagnostics through `swift-log`. `PromptAssembler` and
`PromptAssemblyOptions` are internal runtime types, so you don't call them directly — instead pass a
`Logger` to `PositronicKit.run(..., promptAssemblyLogger:)` to enable diagnostics for that turn.

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
let events = try await chat.run(
    timelineId: timelineId,
    message: "…",
    promptAssemblyLogger: logger
)
```

### Handling Tool Outputs

If the agent calls a tool that requires host-side execution (e.g., a local file system tool not handled by the runtime), you can submit the outputs in a follow-up turn.

```swift
let toolOutputs = [
    ToolOutputSubmission(toolCallId: "call_123", output: "File contents...")
]

let stream = try await chat.run(
    timelineId: timelineId,
    message: "", // Empty message as we're continuing from a tool call
    tools: tools,
    toolOutputs: toolOutputs,
    agentInstanceId: instance.id
)
```

## 3. Core Concepts

### ChatEvent Stream
The stream provides a rich set of events:
- `.delta(.thinking)` and `.delta(.generation)` for streaming text.
- `.delta(.toolCall)` and `.delta(.toolExecution)` for tool progress.
- `.meta(.generationContext)` for retrieved context metadata.
- `.meta(.generationCompleted)` for informational completion metadata.
- `.completion(.generationCompleted)` and `.completion(.streamCompleted)` for terminal events.
- `.error(.toolCallError)`, `.error(.error)`, and `.error(.generationCancelled)` for failure and cancellation handling.

### Agent Persistence
Agents are persistent. Their workspace (`primaryWorkspaceId`) contains their long-term memory, while their private timeline (`privateTimelineId`) stores their internal monologue and history.
