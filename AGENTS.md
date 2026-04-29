# AGENTS

`PositronicKit` — Swift package for agent runtime and prompt composition.

## Layout

- `Package.swift` — package manifest.
- `Sources/PositronicKit` — runtime: orchestration stages, chat engine, tool routing, timelines, workspaces, LLM services.
- `Sources/PKPrompt` — prompt composition: `PromptBuilder` DSL, `PromptNode` IR, assembly, compression, `PromptJournal`.
- `Sources/PKShared` — shared contracts: API models, tool protocols, error types, logging, utilities.
- `Sources/PositronicKitExamples` — runnable examples; double as living documentation.
- `Tests/PKTestSupport` — mocks, fixtures, test helpers (library product).
- `Tests/PositronicKitTests`, `Tests/PKPromptTests`, `Tests/PKSharedTests` — per-module test targets.

## Commands

```
swift build                        # or: make build
swift test                         # or: make test
swift run PositronicKitExamples
make clean
```

## Module Boundaries

| Module | Owns | Does Not Own |
|--------|------|--------------|
| `PKShared` | API models, tool contracts, logging, utilities | Prompt logic, orchestration, persistence |
| `PKPrompt` | Prompt IR, assembly, rendering, compression, journaling | Runtime, persistence, transport |
| `PositronicKit` | Orchestration, chat lifecycle, tool routing, timeline/workspace mgmt | Transport, RPC, hosting, prompt-tree internals |

## Conventions

- Swift 6 concurrency: `Sendable`, actor isolation, no shared mutable state.
- Composition over inheritance. Narrow protocols. Explicit `throws`.
- Structured logging via `PKShared`.
- Tests accompany every behavioral change; use `PKTestSupport` helpers.
- Keep `PositronicKitExamples` compiling and current with public APIs.
- Prefer `JSONSchema`/`JSONSchemaBuilder`; derive from `@Schemable` when schema mirrors a Swift model.
- Fixtures: deterministic, lightweight; prefer reusable builders over inline setup.
- `swift build && swift test` before opening or updating PRs.

## PositronicKit Invariants

- Transport-neutral. Concrete networking, RPC, and hosting belong downstream.
- Downstream pluggability is non-negotiable: persistence, workspace resolution, tool execution, prompting, and UI/network layers are all injectable.
- Consume `PKPrompt` artifacts (`AssembledPrompt`, `RenderedPrompt`). Never reimplement prompt-tree semantics.
- Extension points: persistence protocols, `WorkspaceCreating`/`WorkspaceProtocol`, `PromptSectionProviding`, `ToolRouter`, `ChatTurnPlugin`.
- Core types: `Timeline`, `AgentInstance`, `ChatEngine`, `TimelineManager`, `ToolRouter`, `WorkspaceManager`.

## PKPrompt Invariants

- `PromptNode` = canonical internal IR. `PromptBuilder` first composes structural `Prompt` values; `PromptAssembly` lowers them to nodes.
- `AssembledPrompt` = validated section artifact. `RenderedPrompt` = canonical render output.
- `PromptJournal` = prompt-history primitive. Cache policies determine lifecycle: stable → materialized base, semi-stable → overlays until `compact()`, volatile → current-only, stable mutations → hard reset.
- Author prompts via `var body: some Prompt`, composing `SystemPrompt`, `TextPrompt`, `UserPrompt`, `HistoryPrompt`, and custom `Prompt` types.
- Trait modifiers (`.priority(...)`, `.compression(...)`, `.cachePolicy(...)`) inherit through subtree; resolved once at assembly.
- Three consumption layers: `Prompt → String` | `Prompt → AssembledPrompt → RenderedPrompt` | `RenderedPrompt → PromptJournal`.
