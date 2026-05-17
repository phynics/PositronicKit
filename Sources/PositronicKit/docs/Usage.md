# PositronicKitCore Usage Guide

This guide provides step-by-step examples for integrating `PositronicKitCore` and managing `AgentInstance` within your application.

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
let chat = PositronicKitCore(openAIKey: "sk-...")

// For Ollama
let chat = PositronicKitCore(ollamaModel: "llama3")
```

This provider-backed path is the canonical convenience setup when you want a concrete provider module to supply the runtime initializer.

### Full Initialization (Production)

For production, you should provide persistent stores through the grouped `persistence:` initializer.

```swift
import PositronicKit
import PKShared

let chat = PositronicKitCore(
    llmService: myLLM,
    persistence: .init(
        messageStore: myMessageStore,
        timelinePersistence: myTimelinePersistence,
        workspacePersistence: myWorkspacePersistence,
        memoryStore: myMemoryStore,
        toolPersistence: myToolPersistence,
        agentInstanceStore: myAgentInstanceStore,
        requestOriginStore: myRequestOriginStore,
        agentTemplateStore: myAgentTemplateStore
    ),
    embeddingService: myEmbeddingService,
    timelineManager: myTimelineManager,
    toolRouter: myToolRouter
)
```

### Running a Chat Stream

The `run` method returns an `AsyncThrowingStream<ChatEvent, Error>`. This allows you to process real-time updates as the agent "thinks" and responds.

```swift
import PositronicKit
import PKShared

let chat = PositronicKitCore(
    llmService: myLLM,
    persistence: .init(
        messageStore: myMessageStore,
        timelinePersistence: myTimelinePersistence,
        workspacePersistence: myWorkspacePersistence,
        memoryStore: myMemoryStore,
        toolPersistence: myToolPersistence,
        agentInstanceStore: myAgentInstanceStore,
        requestOriginStore: myRequestOriginStore,
        agentTemplateStore: myAgentTemplateStore
    ),
    embeddingService: myEmbeddingService,
    timelineManager: myTimelineManager,
    toolRouter: myToolRouter
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

If you need verbose prompt assembly diagnostics, pass a `Logger` through `PromptAssemblyOptions`.

```swift
import Logging
import PositronicKit

let promptLogger = Logger(label: "com.example.prompt")

let result = try await PromptAssembler.prepare(
    request,
    options: PromptAssemblyOptions(logger: promptLogger)
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
