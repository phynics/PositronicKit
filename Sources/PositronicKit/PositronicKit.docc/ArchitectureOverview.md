# Architecture Overview

Deep dive into the current PositronicKit runtime design.

## Modularity

PositronicKit keeps transport-neutral runtime orchestration in `PositronicKit`, shared contracts in `PKContracts`, and prompt composition/rendering in `PKPrompt`.

## Facade-Backed Wiring

The runtime is assembled through explicit facade initializers so orchestration services can collaborate without asking downstream applications to configure a shared dependency container.

### Example Usage

```swift
let kit = PositronicKit(languageModel: myLLM)
let answer = try await kit.model.generate("Summarize this note.")
let thread = try await kit.threads.create(title: "Research")
let agent = try await kit.agents.create(name: "Researcher", description: "Summarizes sources.")
try await kit.agents.attach(agent.id, to: thread.id)
let stream = try await thread.send("Summarize the attached sources.")
```

## Data Flow

1. **User Query**: Received via `TurnEngine`.
2. **Context Gathering**: `TurnBriefingBuilder` retrieves relevant memories and filesystem notes.
3. **Prompt Construction**: `PKPrompt` DSL builds a provider-specific prompt.
4. **Execution**: `LLMService` communicates with the AI provider.
5. **Tool Routing**: If the AI calls a tool, the internal router executes runtime-managed tools and defers attached tools for host-side execution when needed.
