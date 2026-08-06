# PKARCH-005: Push structured-output preparation into provider adapters

**Priority:** P3
**Type:** Design + refactor (may touch public adapter interfaces; semver-relevant)
**Depends on:** PKARCH-004 (narrow LLM seam; structured-output adapter should sit at the stream-client seam)
**Blocks:** None
**Status:** Done (commit `0d26dad` in `pkarch-005-structured-output-adapters`)
**Triage:** ready-for-agent

### Summary

The core runtime currently switches on `LLMProvider` in `LLMServiceProtocol+StructuredOutput.swift` to decide how to prepare a structured-output request: native JSON schema for OpenAI/OpenRouter, prompt augmentation for Ollama, synthetic-tool fallback for Anthropic/openAICompatible. This violates the PositronicKit invariant that concrete provider logic lives in dedicated provider targets. This ticket introduces a `StructuredOutputAdapter` seam implemented by each provider target.

### Current Problem

- Adding a new provider requires editing a core PositronicKit file.
- `LLMService+Stream.swift` also contains provider-specific preparation logic (`StructuredOutputExecution.prepareRequest`).
- The synthetic-tool stream rewrite is a provider-specific transformation that currently lives in the core runtime.

### Implementation Requirements

1. Define a small `StructuredOutputAdapter` seam (package or public) with a method like:
   ```swift
   func prepareRequest(
     messages: [LLMMessage],
     tools: [LLMToolDefinition]?,
     output: StructuredOutputRequest
   ) -> PreparedStructuredOutputRequest
   ```
   where `PreparedStructuredOutputRequest` carries the transformed messages, tools, toolChoice, responseFormat, and optional synthetic-tool name for stream rewriting.
2. Implement the adapter in each provider target:
   - `OpenAIStructuredOutputAdapter` — native JSON schema.
   - `OpenRouterStructuredOutputAdapter` — native JSON schema (or delegate to OpenAI).
   - `OllamaStructuredOutputAdapter` — prompt augmentation.
   - `AnthropicStructuredOutputAdapter` — synthetic-tool fallback.
3. Update `LLMService` (or its stream client) to select the adapter based on the configured provider and apply the prepared request before streaming.
4. Move the synthetic-tool stream rewrite behind the adapter seam or into a small shared utility that the adapter controls.
5. Ensure the existing `StructuredOutputExecution` tests continue to pass by routing them through the new adapters.

### Acceptance Criteria

- [x] `StructuredOutputAdapter` seam is defined and documented.
- [x] Each provider target has its own adapter implementation with passing conformance tests.
- [x] No provider switch remains in `Sources/PositronicKit/Services/LLM/` for structured-output preparation.
- [x] Existing structured-output tests pass without behavior regression.
- [x] `make verify` green.
- [x] CHANGELOG.md updated under `Unreleased` if public adapter types are exposed.

### Note

This is marked P3 because it is a worthwhile deepening only if the project is actively adding providers. If the current provider set is stable, this refactor may be deferred until a new provider is added.

### Resolution

Implemented `StructuredOutputAdapter` and `PreparedStructuredOutputRequest` in `PKShared`, a `StructuredOutputAdapterRegistry` for provider registration, and a `DefaultStructuredOutputAdapter` fallback. Added per-provider adapters in each target (`OpenAIStructuredOutputAdapter`, `OpenRouterStructuredOutputAdapter`, `OllamaStructuredOutputAdapter`, `AnthropicStructuredOutputAdapter`, `OpenAICompatibleStructuredOutputAdapter`) and registered them in the provider `register()` entry points. Rewrote `StructuredOutputExecution.prepareRequest` in `Sources/PositronicKit/Services/LLM/LLMServiceProtocol+StructuredOutput.swift` to look up the adapter from the registry, removing the `LLMProvider` switch from the core runtime. Added `StructuredOutputAdapterTests` with direct adapter conformance tests and updated `StructuredOutputPreparationTests` to register adapters. `make verify` green (858 tests / 155 suites). `CHANGELOG.md` updated under `Unreleased`.
