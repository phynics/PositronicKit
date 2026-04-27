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
- Treat `PromptNode` as the canonical internal IR. `PromptBuilder` lowers authored syntax directly into prompt nodes; `AssembledPrompt.Section` is the validated concrete artifact that downstream systems consume.
- Prefer composite `Prompt` types for reuse and primitive leaves like `SystemPrompt`, `TextPrompt`, `HistoryPrompt`, and `UserPrompt` for final content.
- Use `AnyPrompt.build { ... }` as the explicit root prompt container.
- Plain `for` loops inside `PromptBuilder` use positional identity; use `ForEach(...)`, `PromptForEach(...)`, or `PromptBuilder.forEach(...)` when loop identity needs stable domain-derived paths.
- Route prompt semantics via `PromptSectionRole`, section paths, and cache policy metadata rather than stringly-typed section ID checks.
- Think of PKPrompt in four layers: `Prompt -> String`, `Prompt -> AssembledPrompt`, `Prompt -> RenderedPrompt`, and `RenderedPrompt -> PromptJournal`.
- Prefer `try prompt.assemblePrompt()` when a call site needs validated ordering and concrete sections. Prefer `await assembled.render()` as the canonical rendered product; derive plain text, snapshots, and provider projections from that one value.
- `AssembledPrompt.render()` is the canonical render pass. Do not re-render sections ad hoc for hashes, history, or provider conversion unless a test explicitly requires it.
- Compression has two pieces of state: requested strategy (`compression`) and realized outcome (`compressionOutcome` / `compressionReport`). Preserve both when adding budgeting or summarization behavior.
- Use builder modifiers like `.priority(...)`, `.compression(...)`, and `.cachePolicy(...)` to inherit prompt traits instead of duplicating metadata.
- Keep structural paths provider-neutral. If you need journaling-specific layering like base/overlay/volatile, derive a journal path in `PromptJournal` rather than mutating the source section path.
- `PromptJournal` is PKPrompt’s prompt-history primitive: stable sections stay materialized in the base, semi-stable changes become overlays until `compact()`, volatile sections remain current-only, and stable changes require a hard reset plan.

## Additional Notes
- Keep fixtures deterministic and lightweight; prefer reusable builders over duplicated inline setup.
- Prefer `JSONSchema`/`JSONSchemaBuilder` over ad-hoc JSON dictionaries; when a schema mirrors a Swift model, use `@Schemable` and derive it from `Type.schema`.
- Validate changes locally with `swift build` and `swift test` before opening or updating a PR.
