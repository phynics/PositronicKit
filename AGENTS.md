# AGENTS
`PositronicKit` is a Swift package for agent runtime and prompt composition.

## Repository Layout
- `Package.swift`: Package graph and target definitions.
- `Sources/PositronicKit` (target: `PositronicKit`): Runtime orchestration, chat lifecycle, tools, context, timelines, and LLM services.
- `Sources/PKPrompt` (target: `PKPrompt`): Prompt composition, prompt update mechanisms, compression, and PromptBuilder DSL.
- `Sources/PKShared` (target: `PKShared`): Shared API models, tool contracts, utility types, logging, etc.
- `Sources/PositronicKitExamples` (target: `PositronicKitExamples`): Runnable `PKPrompt` and `PositronicKit` examples.
- `Tests/*`: Tests and test support files.

## Build and Test
- Build: `swift build` (or `make build`)
- Test: `swift test` (or `make test`)
- Run examples: `swift run PositronicKitExamples`
- Clean: `make clean`

## Working Conventions
- Prefer small, focused changes that keep module boundaries clear: `PKShared` for contracts/utilities, `PKPrompt` for prompt construction, `PositronicKit` for runtime orchestration.
- Keep `PositronicKitExamples` runnable and aligned with current public APIs. They should also function as documentation.
- Add or update tests with every behavioral change, using helpers from `Tests/PKTestSupport` when they fit.
- Follow Swift 6 concurrency defaults (`Sendable`, actor isolation, `@MainActor`) and avoid shared mutable state.
- Prefer composition over inheritance, narrow protocols, explicit `throws`, and structured logging via `PKShared`.

## PositronicKit Guidance
- Treat `PositronicKit` as an agent-building toolkit centered on timelines, workspaces, agents, tools, and orchestration stages.
- Keep concrete transport, RPC, and client/server hosting models downstream of `PositronicKit`.
- Prefer neutral boundaries like workspace creators, persistence protocols, tool routers, and prompt section providers over embedding downstream deployment concerns in runtime logic.
- Keep provider projection and prompt assembly separate from orchestration. `PositronicKit` should consume `PKPrompt` artifacts, not reimplement prompt-tree semantics.
- When changing orchestration APIs, preserve the ability for downstream applications to plug in their own persistence, workspace resolution, externally hosted tool execution, custom prompting behaviour, and UI/network layers.

## PKPrompt Guidance
- Treat `PromptNode` as the canonical internal IR. `PromptBuilder` lowers authored syntax directly into prompt nodes; `AssembledPrompt` is the validated concrete artifact that downstream systems consume.
- `PromptJournal` is PKPrompt’s prompt-history primitive: stable sections stay materialized in the base, semi-stable changes become overlays until `compact()`, volatile sections remain current-only, and stable changes require a hard reset plan.
- Consumers create their own Prompt types and compose their own Prompts within the `var body: some Prompt`, by composing primitives like `TextPrompt`, `SystemPrompt` and prompt modifiers.
- Think of PKPrompt in three layers: `Prompt -> String` for simplest use case, `Prompt -> AssembledPrompt` for more control over render, `Prompt -> PromptJournal` for managing Prompt updates.
- Use builder modifiers like `.priority(...)`, `.compression(...)`, and `.cachePolicy(...)` to inherit prompt traits instead of duplicating metadata.

## Additional Notes
- Keep fixtures deterministic and lightweight; prefer reusable builders over duplicated inline setup.
- Prefer `JSONSchema`/`JSONSchemaBuilder` over ad-hoc JSON dictionaries; when a schema mirrors a Swift model, use `@Schemable` and derive it from `Type.schema`.
- Validate changes locally with `swift build` and `swift test` before opening or updating a PR.
