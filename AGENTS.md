# AGENTS

## Project Overview
- `PositronicKit` is a Swift package for agent runtime, prompt composition, and shared contracts/utilities.
- The package targets macOS 15+ and uses Swift 6.

## Repository Layout
- `Package.swift`: Package graph and target definitions.
- `Sources/PositronicKit` (target: `PositronicKit`): Runtime orchestration, chat lifecycle, tools, context, timelines, and LLM services.
- `Sources/PKPrompt` (target: `PKPrompt`): Prompt composition, leaf resolution, compression, and pipeline structures.
- `Sources/PKShared` (target: `PKShared`): Shared API models, tool contracts, utility types, and logging.
- `Sources/PositronicKitExamples` (target: `PositronicKitExamples`): Runnable `PKPrompt` and `PositronicKit` examples.
- `Tests/PositronicKitTests`, `Tests/PKPromptTests`, `Tests/PKSharedTests` (targets: `PositronicKitTests`, `PKPromptTests`, `PKSharedTests`): Unit and integration tests.
- `Tests/PKTestSupport` (target: `PKTestSupport`): Mocks, fixtures, and reusable test helpers.

## Build and Test
- Build: `swift build` (or `make build`)
- Test: `swift test` (or `make test`)
- Run examples: `swift run PositronicKitExamples`
- Clean: `make clean`

## Working Conventions
- Prefer small, focused changes that keep module boundaries clear: `PKShared` for contracts/utilities, `PKPrompt` for prompt construction, `PositronicKit` for runtime orchestration.
- Update `Package.swift`, imports, docs, and examples together when renaming or reshaping public APIs.
- Keep `PositronicKitExamples` runnable and aligned with current public APIs; prefer test-backed examples over doc-only snippets.
- Add or update tests with every behavioral change, using helpers from `Tests/PKTestSupport` when they fit.
- Follow Swift 6 concurrency defaults (`Sendable`, actor isolation, `@MainActor`) and avoid shared mutable state.
- Prefer composition over inheritance, narrow protocols, explicit `throws`, and structured logging via `PKShared`.

## PKPrompt Guidance
- Prefer composite `ContextSection` types for reuse and primitive leaf sections for actual rendered content.
- Route prompt semantics via `PromptSectionRole` and `ConcretePromptSection` metadata rather than stringly-typed section ID checks.
- Think of PKPrompt in three layers: `Prompt -> String`, `Prompt -> Structured Prompt`, and `Prompt -> Structured Prompt History`.
- Prefer `prompt.sections()` when a call site needs concrete sections and `try prompt.assembledPrompt()` only when ordering validation or canonical assembled rendering is needed.
- Prefer `await assembled.rendered()` as the canonical rendered prompt product; derive plain text, snapshots, and provider messages from that one value.
- For prompt history and prefix caching flows, pair `assembled.sections` with `rendered.sectionsByID` and record them through `TimelinePromptHistory` instead of re-deriving ad-hoc diffs.
- Resolve prompt trees into stable `ConcretePromptSection` values before hashing, token budgeting, history diffs, or provider conversion.
- Use builder modifiers like `.priority(...)`, `.compression(...)`, and `.cachePolicy(...)` to inherit prompt traits instead of duplicating metadata.

## Additional Notes
- Keep fixtures deterministic and lightweight; prefer reusable builders over duplicated inline setup.
- Prefer `JSONSchema`/`JSONSchemaBuilder` over ad-hoc JSON dictionaries; when a schema mirrors a Swift model, use `@Schemable` and derive it from `Type.schema`.
- Validate changes locally with `swift build` and `swift test` before opening or updating a PR.
