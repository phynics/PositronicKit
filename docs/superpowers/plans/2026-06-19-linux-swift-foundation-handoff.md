# PositronicKit Linux And Swift Foundation Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `PKShared`, `PKPrompt`, and `PositronicKit` portable to Linux, add `PKLocalEmbeddings` as the platform-local embedding product, keep Apple-optimized implementations where justified, and document and verify product-level Linux support in CI.

**Architecture:** Preserve the current public module layout while isolating Apple-only behavior behind conditional compilation, SwiftPM traits, and dedicated optional targets. Keep runtime, shared contracts, prompt composition, provider transports, and examples portable; move local embeddings out of the portable core into `PKLocalEmbeddings`; use Natural Language as the default Apple backend and a fixed FastEmbed/MiniLM backend on Linux; split vector math into portable and Accelerate-backed implementations behind the existing `VectorMath` API.

**Tech Stack:** Swift 6.1, Swift Package Manager traits, Testing/XCTest, GitHub Actions, Foundation, FoundationNetworking, Accelerate, NaturalLanguage, PKFastEmbed

## Global Constraints

- Raise the manifest to `// swift-tools-version: 6.1`.
- Declare the additive `MiniLMEmbeddings` package trait for trait-enabled Apple MiniLM support.
- Do not add `swift-foundation` as a package dependency.
- Files that use `URLSession`, `URLRequest`, `URLResponse`, or `HTTPURLResponse` must add conditional `FoundationNetworking` imports.
- `PKShared`, `PKPrompt`, and `PositronicKit` are mandatory Linux products.
- `PKOpenRouterProvider`, `PKOllamaProvider`, `PKTestSupport`, and `PositronicKitExamples` must build on Linux.
- `PKOpenAIProvider` must be attempted on Linux and only excluded if a precise blocker is demonstrated.
- `PKLocalEmbeddings` is an optional product with one public `LocalEmbeddingService` API across platforms.
- Keep the existing `VectorMath` public API.
- Portable vector math must be tested on macOS and Linux; Accelerate equivalence must be tested on macOS.
- Default Apple builds must not build or link `PKFastEmbed`; `LocalEmbeddingService()` must continue to use Natural Language there.
- Linux embeddings must use a fixed in-process MiniLM configuration with checksum-validated model files and no provider fallback.
- Foundation Models types must not leak into `PKShared`, `PKPrompt`, or `PositronicKit` public APIs.

---

### Task 1: Lock In Portable Vector Math

**Files:**
- Modify: `Tests/PositronicKitTests/MockVectorStoreTests.swift`
- Create: `Tests/PositronicKitTests/VectorMathTests.swift`
- Modify: `Sources/PositronicKit/Utilities/VectorMath.swift`

**Interfaces:**
- Consumes: `VectorMath.cosineSimilarity(_:_:)`, `VectorMath.normalize(_:)`
- Produces: portable backend behavior for empty, mismatched, zero, negative, and large-vector cases without changing the public API

- [ ] Write failing tests for portable vector behavior and macOS differential coverage.
- [ ] Run `swift test --filter VectorMathTests` and confirm failure is due to missing portable backend hooks or unsupported assumptions.
- [ ] Implement internal portable and Accelerate-backed logic in `VectorMath.swift` with compile-time dispatch.
- [ ] Run `swift test --filter VectorMathTests` and confirm pass.

### Task 2: Move Local Embeddings Into `PKLocalEmbeddings`

**Files:**
- Modify: `Sources/PositronicKit/Services/Embeddings/EmbeddingServiceProtocol.swift`
- Modify: `Sources/PositronicKit/Services/Embeddings/EmbeddingService.swift`
- Modify: `Sources/PositronicKit/Services/Embeddings/NoOpEmbeddingService.swift`
- Delete: `Sources/PositronicKit/Services/Embeddings/LocalEmbeddingService.swift`
- Create: `Sources/PKLocalEmbeddings/PKLocalEmbeddings.swift`
- Create: `Sources/PKLocalEmbeddings/LocalEmbeddingService.swift`
- Create: `Sources/PositronicKit/Services/Embeddings/EmbeddingError.swift`
- Modify: `Package.swift`
- Modify: `Tests/PositronicKitTests/EmbeddingServiceTests.swift`

**Interfaces:**
- Consumes: `EmbeddingServiceProtocol`
- Produces: optional `PKLocalEmbeddings` product with a single public `LocalEmbeddingService` facade while keeping provider-neutral embedding contracts in `PositronicKit`

- [ ] Write failing tests that assert `PositronicKit` no longer exposes `LocalEmbeddingService` and that `PKLocalEmbeddings` owns the public embedding facade.
- [ ] Run focused embedding tests and confirm failure.
- [ ] Move the concrete embedding implementation into `PKLocalEmbeddings`, preserve Natural Language behavior on Apple, and keep portable core types provider-neutral.
- [ ] Re-run focused embedding tests and confirm pass on the current platform.

### Task 3: Add MiniLM Backends, Trait Gating, And FastEmbed Bridge Integration

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PKMiniLMLinuxBackend/LinuxMiniLMEmbeddingBackend.swift`
- Create: `Sources/PKMiniLMTraitBackend/TraitMiniLMEmbeddingBackend.swift`
- Create: `Sources/PKLocalEmbeddings/MiniLMEmbeddingBackendProtocol.swift`
- Create: any package glue required for the pinned `PKFastEmbed` dependency
- Create: `Tests/PKLocalEmbeddingsTests/MiniLMEmbeddingContractTests.swift`
- Create: `Tests/PKLocalEmbeddingsTests/LocalEmbeddingServiceAppleTests.swift`
- Create: `Tests/PKLocalEmbeddingsTests/LocalEmbeddingServiceMiniLMTests.swift`

**Interfaces:**
- Consumes: `PKLocalEmbeddings.LocalEmbeddingService`, package traits, native bridge contract
- Produces: Linux default MiniLM embeddings, trait-enabled Apple MiniLM initializer, and shared MiniLM contract coverage

- [ ] Write failing tests for Linux/trait MiniLM shape, normalization, deterministic fixture output, batch ordering, initialization failures, and checksum rejection.
- [ ] Run focused local-embedding tests and confirm failure.
- [ ] Raise the manifest to Swift 6.1, declare `MiniLMEmbeddings`, add the conditional backend targets, and integrate the exact-pinned `PKFastEmbed` bridge without linking it into default Apple builds.
- [ ] Implement the `PKLocalEmbeddings` facade so Apple defaults to Natural Language, Linux defaults to MiniLM via `LocalEmbeddingService(modelDirectory:)`, and trait-enabled Apple exposes `LocalEmbeddingService(miniLMModelDirectory:)`.
- [ ] Re-run focused local-embedding tests and confirm pass for the active configuration.

### Task 4: Make Networking Sources Linux-Compatible

**Files:**
- Modify: `Sources/PositronicKit/Services/LLM/ProviderHTTPTransport.swift`
- Modify: `Sources/PositronicKit/Services/LLM/ProviderHTTPFailure.swift`
- Modify: `Sources/PKOpenRouterProvider/OpenRouterClient.swift`
- Modify: `Sources/PKOllamaProvider/OllamaClient.swift`
- Modify: `Sources/PKOpenAIProvider/OpenAIClient.swift`
- Modify: `Tests/PositronicKitTests/Services/LLM/Providers/ProviderTransportContractTests.swift`
- Modify: `Tests/PositronicKitTests/Services/LLM/Providers/ProviderHTTPFailureTests.swift`

**Interfaces:**
- Consumes: `ProviderHTTPTransport`, provider clients, HTTP failure parsing
- Produces: Darwin/Linux-compatible networking imports with unchanged behavior

- [ ] Add or extend tests that cover the HTTP transport and failure parsing surfaces touched by Linux Foundation types.
- [ ] Run focused provider tests and confirm failure if imports or response handling assumptions break.
- [ ] Add `FoundationNetworking` guards to every source file that uses networking Foundation APIs.
- [ ] Run focused provider tests and confirm pass.

### Task 5: Remove The Package-Level macOS Lock And Mark Apple-Only Targets

**Files:**
- Modify: `Package.swift`

**Interfaces:**
- Consumes: existing product and target graph
- Produces: manifest-level Linux portability for portable targets and explicit Apple-only markers for Apple-specific targets

- [ ] Write a failing product build command for one Linux-targeted product if the current manifest still assumes macOS-only packaging.
- [ ] Remove the package-level macOS-only assumption while preserving Apple deployment floors where needed and keeping optional Apple-only capability markers visible.
- [ ] Add comments and target declarations that make Apple-only targets and dependencies obvious.
- [ ] Run `swift build` locally to confirm manifest validity.

### Task 6: Verify Core And Optional Portable Products

**Files:**
- Modify: `Sources/PositronicKitExamples/main.swift`
- Modify: any example or support files that fail once Linux portability is enforced
- Modify: `Tests/PKTestSupport/DependencyCompatibility.swift`

**Interfaces:**
- Consumes: product graph, examples, test support
- Produces: Linux-buildable `PKTestSupport` and `PositronicKitExamples`, plus any necessary compatibility fixes

- [ ] Run product-targeted build commands for `PKShared`, `PKPrompt`, `PositronicKit`, `PKOpenRouterProvider`, `PKOllamaProvider`, `PKOpenAIProvider`, `PKLocalEmbeddings`, and `PositronicKitExamples`.
- [ ] Add failing tests or build assertions for any portable examples/support regressions encountered.
- [ ] Implement the smallest compatibility fixes needed.
- [ ] Re-run the product builds and focused tests.

### Task 7: Add Linux CI And Support Matrix Documentation

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: package products, support policy from the handoff spec
- Produces: required Ubuntu validation for supported products and a documented support matrix

- [ ] Add a failing CI definition for Linux product builds if the workflow only validates macOS.
- [ ] Extend CI with explicit Ubuntu product build commands and `swift test`.
- [ ] Extend macOS CI to run default Apple embedding tests plus `swift build --product PKLocalEmbeddings --traits MiniLMEmbeddings` and `swift test --traits MiniLMEmbeddings`.
- [ ] Add a README support matrix that distinguishes Linux-supported, Apple-supported, Apple-only, and blocked products, and document the re-embedding requirement when moving persisted content across Apple and Linux.
- [ ] Re-run local macOS verification commands that remain available in this environment.

### Task 8: Final Verification

**Files:**
- No source changes expected

**Interfaces:**
- Consumes: full package
- Produces: final verification evidence for macOS and CI-ready Linux validation

- [ ] Run `swift build`.
- [ ] Run `swift test`.
- [ ] Run `swift test --parallel --num-workers 2`.
- [ ] Summarize any Linux-only validation that must be confirmed by CI after local completion.
