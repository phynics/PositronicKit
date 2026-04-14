# MonadCore Usage Guide

This guide provides step-by-step examples for integrating `ChatEngine` and managing `AgentInstance` within your application.

## 1. Managing Agent Instances

`AgentInstance` represents a live agent with its own workspace and private timeline. You manage these instances using the `AgentInstanceManager`.

### Creating an Instance

To create a new agent instance, use the `createInstance` method. You can optionally seed it from an `AgentTemplate`.

```swift
import PositronicKit
import PKShared
import Dependencies

@Dependency(\.agentInstanceManager) var manager

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

// For OpenAI
let chat = MonadCore(openAIKey: "sk-...")

// For Ollama
let chat = MonadCore(ollamaModel: "llama3")
```

### Full Initialization (Production)

For production, you should provide persistent stores and specific service configurations.

```swift
import PositronicKit
import PKShared

let chat = MonadCore(
    llmService: myLLM,
    messageStore: myMessageStore,
    timelineManager: myTimelineManager,
    toolRouter: myToolRouter,
    agentInstanceStore: myAgentInstanceStore,
    clientStore: myClientStore,
    timelinePersistence: myTimelinePersistence,
    workspacePersistence: myWorkspacePersistence,
    memoryStore: myMemoryStore,
    toolPersistence: myToolPersistence,
    agentTemplateStore: myAgentTemplateStore,
    embeddingService: myEmbeddingService
)
```

### Running a Chat Stream

The `run` method returns an `AsyncThrowingStream<ChatEvent, Error>`. This allows you to process real-time updates as the agent "thinks" and responds.

```swift
import PositronicKit
import PKShared

let chat = MonadCore(
    llmService: myLLM,
    messageStore: myMessageStore,
    timelineManager: myTimelineManager,
    toolRouter: myToolRouter,
    agentInstanceStore: myAgentInstanceStore,
    clientStore: myClientStore,
    timelinePersistence: myTimelinePersistence,
    workspacePersistence: myWorkspacePersistence,
    memoryStore: myMemoryStore,
    toolPersistence: myToolPersistence,
    agentTemplateStore: myAgentTemplateStore,
    embeddingService: myEmbeddingService
)

let stream = try await chat.run(
    timelineId: timelineId,
    message: "What are the latest trends in Swift concurrency?",
    agentInstanceId: instance.id // The agent we created earlier
)

for try await event in stream {
    switch event {
    case .delta(let text):
        // Received a text delta (streaming response)
        print(text, terminator: "")
        
    case .status(let status):
        // Agent status changed (e.g., "Thinking...", "Using tool...")
        print("\nStatus: \(status)")
        
    case .toolCall(let name, let arguments):
        // Agent is calling a tool
        print("\nCalling tool: \(name)")
        
    case .generationContext(let metadata):
        // Initial context gathered for the turn (RAG memories, files)
        print("\nContext: \(metadata.files.count) files referenced")
        
    case .generationFinished:
        print("\nDone.")
        
    default:
        break
    }
}
```

### Handling Tool Outputs

If the agent calls a tool that requires client-side execution (e.g., a local file system tool not handled by the server), you can submit the outputs in a follow-up turn.

```swift
let toolOutputs = [
    ToolOutputSubmission(callId: "call_123", output: "File contents...")
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
- `.delta`: Incremental text updates.
- `.status`: High-level agent activity status.
- `.toolCall`: Notification of a tool being invoked.
- `.generationContext`: Metadata about the RAG context used.
- `.generationCancelled`: Sent if the task is cancelled.

### Agent Persistence
Agents are persistent. Their workspace (`primaryWorkspaceId`) contains their long-term memory, while their private timeline (`privateTimelineId`) stores their internal monologue and history.
