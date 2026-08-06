---
Priority: P0
Type: Code duplication
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: High — verified byte-identical implementations
Owner: —
Effort: S
Review: Code review 2026-07-29
Pinned revision: a354632
---

# PKCR-002 — Deduplicate structured-output adapters

## Summary

Three pairs of structured-output adapter types have identical or near-identical implementations:

1. **`OpenAICompatibleStructuredOutputAdapter` ≡ `OllamaStructuredOutputAdapter`** — byte-identical `prepareRequest` bodies (only doc comments and type names differ).
2. **`AnthropicStructuredOutputAdapter` ≡ `DefaultStructuredOutputAdapter`** (in its `.jsonSchema` case) — both use the synthetic-tool pattern identically.
3. **The `.jsonObject` case** is byte-identical across all 5 adapter implementations.

## Current problem

- `Sources/PKOpenAIProvider/OpenAICompatibleStructuredOutputAdapter.swift` (45 lines) — identical to Ollama adapter.
- `Sources/PKOllamaProvider/OllamaStructuredOutputAdapter.swift` (42 lines) — identical to OpenAI-compatible adapter.
- `Sources/PKAnthropicProvider/AnthropicStructuredOutputAdapter.swift` — `.jsonSchema` case identical to `DefaultStructuredOutputAdapter`.
- All 5 adapters have identical `.jsonObject` handling.

## Implementation requirements

1. Create a single `PromptAugmentedJSONSchemaAdapter` in `PKShared` that uses prompt augmentation + `.jsonSchema` response format (replaces both `OpenAICompatibleStructuredOutputAdapter` and `OllamaStructuredOutputAdapter`).
2. Make `AnthropicStructuredOutputAdapter` use `DefaultStructuredOutputAdapter` directly (or make it a typealias if the type name matters for debugging).
3. Add a default `prepareRequest` implementation in the `StructuredOutputAdapter` protocol extension that handles `.jsonObject` uniformly — providers only override `.jsonSchema`.
4. Update provider factory registration sites (`PKOpenAIProvider.swift`, `PKOllamaProvider.swift`, `PKAnthropicProvider.swift`) to register the shared types.
5. Delete the now-redundant adapter files.
6. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [x] `OpenAICompatibleStructuredOutputAdapter.swift` and `OllamaStructuredOutputAdapter.swift` deleted or replaced with typealiases.
- [x] `AnthropicStructuredOutputAdapter` delegates to `DefaultStructuredOutputAdapter` or is a typealias.
- [x] `.jsonObject` case handled in protocol extension, not duplicated 5 times.
- [x] Provider factories register correct adapter types.
- [x] `swift build` succeeds.
- [x] `swift test` passes (1598+ tests).
- [x] `CHANGELOG.md` updated.

## Resolution

Done 2026-07-29. Added `jsonObjectRequest` helper in `StructuredOutputAdapter` protocol extension and `PromptAugmentedJSONSchemaAdapter` in `PKShared`. `PKOpenAIProvider` and `PKOllamaProvider` now register `PromptAugmentedJSONSchemaAdapter`; `PKAnthropicProvider` now registers `DefaultStructuredOutputAdapter`. Deleted `OpenAICompatibleStructuredOutputAdapter.swift`, `OllamaStructuredOutputAdapter.swift`, and `AnthropicStructuredOutputAdapter.swift`. Moved `OpenAICompatibleStructuredOutputAdapterTests` to `PKSharedTests/PromptAugmentedJSONSchemaAdapterTests.swift`. Updated 4 test files to reference the new types and removed now-unused `@testable import` lines. `swift build` and `swift test` green (1610 tests, 238 suites).
