# AGENTS

## Project Overview
- `PositronicKit` is a Swift Package that provides agent runtime, prompt composition, and shared contracts/utilities.
- The package targets macOS 15+ and uses Swift 6.

## Repository Layout
- `Package.swift`: Package graph and target definitions.
- `Sources/PositronicKit` (target: `PositronicKit`): Runtime orchestration, chat lifecycle, tools, context, timelines, and LLM services.
- `Sources/PKPrompt` (target: `PKPrompt`): Body-based prompt/context composition, prompt leaf resolution, compression, and prompt pipeline structures.
- `Sources/PKShared` (target: `PKShared`): Shared API models, tool contracts, utility types, and logging.
- `Tests/PositronicKitTests`, `Tests/PKPromptTests`, `Tests/PKSharedTests` (targets: `PositronicKitTests`, `PKPromptTests`, `PKSharedTests`): Unit/integration tests.
- `Tests/PKTestSupport` (target: `PKTestSupport`): Mocks, fixtures, and reusable test helpers.

## Build and Test
- Build: `swift build` (or `make build`)
- Test: `swift test` (or `make test`)
- Clean: `make clean`

## Working Conventions
- Prefer small, focused changes that keep target/module boundaries clear.
- Keep shared data contracts in the shared module; keep orchestration in the core runtime module.
- Update `Package.swift`, imports, and docs together when renaming modules/targets.
- When adding tests, prefer using existing helpers in `Tests/PKTestSupport`.
- In `PKPrompt`, prefer composite `ContextSection` types for reuse and primitive leaf sections for actual rendered content.
- Route prompt semantics via `PromptSectionRole` and resolved leaves rather than stringly-typed section ID checks.

## Best Practices
- Follow Swift 6 strict concurrency defaults (`Sendable`, actor isolation, `@MainActor`) and avoid introducing shared mutable state.
- Keep public API changes intentional: update access control, docs, and tests together when adding or changing exported types.
- Prefer composition over inheritance, and keep protocols narrow and role-focused to reduce coupling between targets.
- Use explicit error propagation (`throws`) for recoverable failures; avoid silently swallowing errors.
- Keep logging structured and consistent via shared logging utilities in `PKShared`.
- Add or update tests with every behavioral change; cover happy paths, edge cases, and failure paths.
- Keep fixtures deterministic and lightweight; prefer reusable builders/helpers over duplicated inline setup.
- Preserve module boundaries: `PKShared` for contracts/utilities, `PKPrompt` for prompt construction, `PositronicKit` for runtime orchestration.
- Resolve prompt trees into stable leaves before hashing, token budgeting, history diffs, or provider message conversion.
- Use builder modifiers like `.priority(...)`, `.compression(...)`, and `.cachePolicy(...)` to set inherited prompt traits instead of duplicating metadata across composite sections.
- Prefer `JSONSchema`/`JSONSchemaBuilder` schema definitions over ad-hoc JSON dictionaries; when a schema mirrors a Swift model, use the provided `@Schemable` macro on a `Codable` type and derive the schema from its generated `schema` property.
- Validate changes locally with `swift build` and `swift test` before opening or updating a PR.
