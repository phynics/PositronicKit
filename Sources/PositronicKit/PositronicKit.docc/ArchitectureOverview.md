# Architecture overview

Deep dive into the current PositronicKit runtime design.

## Module boundaries

- `PKContracts` owns runtime-neutral provider, tool, structured-output, and diagnostic contracts.
- `PKPrompt` owns prompt composition, assembly, rendering, compression, and journaling.
- `PKRuntime` owns domain state, orchestration, durability, and Workspace dispatch.
- Provider products adapt concrete services to `PKContracts` without importing the runtime.

## Facade-backed wiring

The runtime is assembled through explicit facade initializers so orchestration services can collaborate without asking downstream applications to configure a shared dependency container.

### Example usage

```swift
let kit = PKRuntime(languageModel: myLLM)
let answer = try await kit.model.generate("Summarize this note.")
let timeline = try await kit.timelines.create(title: "Research")
let agent = try await kit.agents.create(name: "Researcher", description: "Summarizes sources.")
try await kit.agents.attach(agent.id, to: timeline.id)
let turn = try await timeline.startTurn("Summarize the attached sources.")
for await event in turn.events() {
    // Render future Turn events.
    _ = event
}
```

## Data Flow

1. **User Query**: Received via `TurnEngine`.
2. **Agent continuity**: Managed admission captures a typed `AgentContextSnapshot` from the
   configured `AgentContextSource`; direct Turns skip Agent context entirely.
3. **Turn context**: Timeline-scoped additions remain injectable and independent of Agent continuity.
4. **Prompt Construction**: `PKPrompt` DSL builds a provider-specific prompt with reserved
   `agent.identity`, `agent.instructions`, `agent.memory`, and `agent.primary-timeline-summary` sections.
5. **Admission and execution**: `TimelineRuntimeRepository` records the admitted input and authority
   before provider or Workspace side effects begin.
6. **Execution**: `LLMService` communicates with the AI provider.
7. **PKTool routing**: If the AI calls a tool, the internal router executes runtime-managed tools and
   defers attached tools for host-side execution when needed.

`PromptJournal` observes assembled prompt state for provider prompt reuse. It does not replace
semantic Timeline history or own Turn durability.
