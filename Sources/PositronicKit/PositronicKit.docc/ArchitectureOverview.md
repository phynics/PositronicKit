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
2. **Agent continuity**: Managed admission captures a typed `AgentContextSnapshot` from the
   configured `AgentContextSource`; direct Turns skip Agent context entirely.
3. **Context Gathering**: Thread-scoped context remains injectable and independent of Agent continuity.
4. **Prompt Construction**: `PKPrompt` DSL builds a provider-specific prompt with reserved
   `agent.identity`, `agent.instructions`, `agent.memory`, and `agent.primary-thread-summary` sections.
5. **Execution**: `LLMService` communicates with the AI provider.
6. **Tool Routing**: If the AI calls a tool, the internal router executes runtime-managed tools and defers attached tools for host-side execution when needed.
