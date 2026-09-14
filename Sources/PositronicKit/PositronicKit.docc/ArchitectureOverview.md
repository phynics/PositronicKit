# Architecture overview

PositronicKit keeps the public runtime small while its internal graph coordinates model inference,
durable Thread history, Agent context, and Workspace tools.

## Module boundaries

- `PKContracts` owns provider, tool, structured-output, and diagnostic contracts.
- `PKPrompt` owns prompt composition, assembly, rendering, compression, and journaling.
- `PositronicKit` owns domain state, orchestration, persistence, and Workspace dispatch.
- Provider products adapt concrete services to `PKContracts` without importing the runtime.

The facade is the composition root. Consumers use `model`, `threads`, `agents`, and `workspaces`
capabilities while managers, registries, and pipeline stages remain internal.

## Facade-backed wiring

The runtime is assembled through explicit facade initializers. A configured provider is enough for a
small integration:

```swift
let kit = PositronicKit(languageModel: myLLM)
let agent = try await kit.agents.create(name: "Researcher", description: "Summarizes sources.")
let thread = try await kit.threads.create(title: "Research", attaching: agent.id)
let turn = try await thread.startTurn("Summarize the attached sources.")
let outcome = try await turn.outcome()
print(outcome)
```

For a detached Thread, use `startDirectTurn(_:context:options:)` and supply the complete
`DirectTurnContext`. Both paths return a `TurnHandle` whose events and durable outcome describe the
same admitted Turn.

## Data flow

1. `ThreadHandle` validates the request and admits the Turn through the
   `ThreadRuntimeRepository`, which records the input and captures execution authority.
2. Managed admission captures an `AgentContextSnapshot` from `AgentContextSource`. Direct Turns
   use only their explicit `DirectTurnContext` and Thread-bound Workspaces.
3. `PKPrompt` assembles the provider prompt. `PromptJournal` observes assembled prompt state and
   does not replace semantic Thread history.
4. `LLMService` streams provider output and coordinates model rounds.
5. The `call_tool` dispatcher routes Workspace tools against the immutable admission snapshot.
6. The runtime records tool results, terminal messages, and the `TurnOutcome` through the same
   `ThreadRuntimeRepository`.
