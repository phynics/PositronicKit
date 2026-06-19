# PositronicKit Linux and Swift Foundation Migration Handoff

## Objective

Make `PKShared`, `PKPrompt`, and `PositronicKit` build and test on Linux with Swift 6. Attempt Linux support for every other existing product, isolating only capabilities that require Apple frameworks. Preserve optimized Apple implementations where they provide a material benefit, while providing behaviorally equivalent portable implementations behind the same public API.

This task supersedes the narrower Linux-validation item in `2026-06-19-positronickit-ticket-batch.md`.

## Required Outcome

- `PKShared`, `PKPrompt`, and `PositronicKit` build and test on both macOS and Linux.
- `PKOpenRouterProvider`, `PKOllamaProvider`, `PKTestSupport`, and `PositronicKitExamples` build on Linux.
- `PKOpenAIProvider` builds on Linux if the pinned MacPaw/OpenAI dependency supports it. Any remaining blocker must be demonstrated by CI or a reproducible build command and documented in the product support matrix.
- `PKLocalEmbeddings` provides one in-process local embedder per platform: Apple Natural Language on Apple platforms and a fixed FastEmbed model on Linux.
- Apple-only implementations are isolated and visibly marked in the manifest, source, documentation, and CI.
- macOS continues to use Accelerate for vector operations while Linux uses a tested portable backend through the existing `VectorMath` API.
- Linux CI prevents regressions in every product classified as portable.

## Foundation Strategy

Do not add `swift-foundation` as a package dependency. It ships with Linux Swift toolchains and is re-exported through the Linux `Foundation` module. Keep `import Foundation` initially to minimize source churn.

Files that use `URLSession`, `URLRequest`, `URLResponse`, or `HTTPURLResponse` must add:

```swift
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
```

Do not mechanically replace every `Foundation` import with `FoundationEssentials`. A later focused change may adopt fine-grained Foundation modules after Linux compatibility is established and measured.

## Platform Classification

### Portable Core

- `PKShared`
- `PKPrompt`
- `PositronicKit`, excluding concrete Apple-framework implementations

These products are mandatory on Linux. Public provider contracts, orchestration, prompt composition, persistence protocols, filesystem tools, HTTP error handling, and portable vector math belong here.

### Portable Provider Candidates

- `PKOpenRouterProvider`
- `PKOllamaProvider`
- `PKOpenAIProvider`

The first two own their URLSession transports and should become portable by importing `FoundationNetworking`. The pinned MacPaw/OpenAI source already contains Linux-oriented `FoundationNetworking` imports, so its provider target must be attempted on Linux before it is classified as unsupported. Avoid excluding the entire provider because of an unverified manifest or transitive dependency concern.

### Apple-Only Capabilities

- Natural Language sentence embeddings using `NLEmbedding`
- A future `PKFoundationModelsProvider` using Apple's `FoundationModels` framework
- Accelerate as an optimized vector-math backend, not as the only implementation

Apple-only code must use capability checks such as `#if canImport(NaturalLanguage)` and `#if canImport(FoundationModels)`, plus appropriate `@available` annotations. Comments in `Package.swift` and the README support matrix must identify why each capability is Apple-only and state the portable alternative when one exists.

### Platform-Local Embeddings

- `PKLocalEmbeddings` is an optional product with a single public `LocalEmbeddingService` API.
- Apple builds use `NLEmbedding.sentenceEmbedding(for: .english)` from Natural Language.
- Linux builds use FastEmbed in-process with one package-pinned `all-MiniLM-L6-v2` model configuration.
- Provider adapters do not supply local embeddings and are not fallback paths for this product.

## Vector Math Design

Keep the existing public surface:

```swift
public enum VectorMath {
    public static func cosineSimilarity(_ vectorA: [Double], _ vectorB: [Double]) -> Double
    public static func normalize(_ vector: [Double]) -> [Double]
}
```

Split implementation responsibility into internal backends:

- `PortableVectorMath`: dependency-free Swift loops for dot product, squared magnitudes, and normalization.
- `AccelerateVectorMath`: vDSP implementation compiled only when `Accelerate` is importable.
- `VectorMath`: compile-time dispatcher that selects Accelerate when present and the portable backend otherwise.

Do not add `swift-numerics`, BLAS, or a C/C++ SIMD dependency for these two operations. Swift Numerics does not provide shaped-array dot product or normalization, while native BLAS and C++ SIMD integrations would add disproportionate build and deployment complexity.

Tests must execute the portable backend on macOS as well as Linux. On macOS, differential tests must compare portable and Accelerate results within an explicit floating-point tolerance. Cover empty vectors, mismatched lengths, zero vectors, ordinary values, negative values, and large vectors.

## Local Embeddings

Move `LocalEmbeddingService` out of the portable core and into a new optional `PKLocalEmbeddings` product. The portable core retains `EmbeddingServiceProtocol`, `NoOpEmbeddingService`, and provider-neutral embedding errors. Existing Apple callers must migrate from importing `PositronicKit` alone to also importing `PKLocalEmbeddings`; document this source change explicitly.

`PKLocalEmbeddings` keeps the same `EmbeddingServiceProtocol` behavior on every platform but selects exactly one implementation at compile time:

- On Apple platforms, use `NLEmbedding.sentenceEmbedding(for: .english)` and preserve the current behavior.
- On Linux, call a narrow Swift-to-C bridge around FastEmbed. Inference, tokenization, pooling, and normalization all run in-process. The initial implementation supports only the package-pinned `all-MiniLM-L6-v2` configuration and returns 384-dimensional normalized vectors.

Maintain the Linux native bridge as a companion `PKFastEmbed` package that publishes versioned Linux x86_64 and aarch64 native artifacts and exposes a C module to Swift. Pin the companion package to an exact release in PositronicKit. The bridge owns Rust memory, converts errors into stable C result codes, and copies completed vectors into Swift-owned memory. Its public C surface covers model initialization, single and batch embedding, vector dimensions, and teardown; do not expose FastEmbed or ONNX Runtime types through Swift APIs.

Model files are not committed to the PositronicKit repository. On Linux, initialize with `LocalEmbeddingService(modelDirectory:)`; the directory must contain the package-pinned MiniLM model and tokenizer files, which the service verifies against hard-coded SHA-256 checksums before native initialization. Model downloading and cache ownership belong to the host application. Tests use a CI-cached copy of the pinned files and never resolve an unpinned latest model revision.

This task does not add runtime model selection, provider fallback, or a general embedding profile registry. Embeddings are platform-local derived data: Apple Natural Language vectors and Linux MiniLM vectors must never share a similarity index. Moving persisted content between Apple and Linux requires rebuilding all embeddings on the destination platform. Document this constraint in the public API and README.

## Foundation Models Provider

Add `PKFoundationModelsProvider` only after the existing products pass the Linux build. It is an optional Apple-only adapter that conforms to the same provider contracts used by other adapters.

Requirements:

- Compile only where `FoundationModels` is importable.
- Use platform availability annotations matching the framework SDK.
- Check runtime model availability and convert unavailable states into stable `PKError` values.
- Keep Foundation Models prompt/session conversion inside the provider target.
- Do not add Foundation Models types to `PKShared`, `PKPrompt`, or `PositronicKit` public APIs.
- Test request conversion and unavailable-state mapping on macOS; do not require it in Linux CI.

If SwiftPM cannot conditionally expose the product cleanly with the package's selected tools version, keep the target source capability-guarded and document the product as Apple-only. Do not create a second package manifest.

## Dependency Audit

Audit direct and transitive dependencies before source changes:

| Dependency | Expected classification | Required action |
| --- | --- | --- |
| `swift-log` | Cross-platform | Verify in Linux build. |
| `swift-dependencies` | Cross-platform with Linux support paths | Verify `PKTestSupport` and tests. |
| `ErrorKit` | Declares Linux conditionals | Verify actual compilation and errors. |
| `swift-json-schema` | Candidate cross-platform | Verify macro/plugin and runtime products on Linux. |
| MacPaw/OpenAI | Candidate cross-platform | Build its async path on Linux; capture any Combine-related blocker precisely. |
| `fastembed-rs` and ONNX Runtime | Linux in-process local embeddings | Pin native runtime and model revisions; expose only a narrow C bridge to Swift. |
| `Accelerate` | Apple-only | Retain only in optimized backend. |
| `NaturalLanguage` | Apple-only | Use as the Apple backend of `PKLocalEmbeddings`. |
| `FoundationModels` | Apple-only | Keep in optional provider target. |
| `Observation` | Toolchain module | Verify on the minimum Linux Swift toolchain; isolate or replace only if compilation proves it unavailable. |

Do not classify a dependency as Apple-only solely because its manifest lists Apple deployment floors. SwiftPM platform declarations describe Apple deployment versions and do not by themselves prove Linux incompatibility.

## Manifest and Documentation

Update `Package.swift` to remove the package-level assumption that macOS is the only supported platform. Apple deployment floors remain for Apple builds. Add concise comments beside Apple-only targets or dependencies.

Add a README product matrix with these states:

- Supported on Linux
- Supported on Apple platforms
- Apple-only
- Temporarily blocked, with a linked or documented reproducible reason

Document that Linux uses Swift's toolchain-provided open-source Foundation implementation. Do not describe `swift-foundation` as a separately linked application dependency.

## CI and Verification

Retain the existing macOS build, test, and parallel-test jobs. Add an Ubuntu job using the same supported Swift major/minor version as the package tools version or a documented newer minimum.

The Linux job must run explicit product builds so an optional product cannot silently escape validation:

```bash
swift build --product PKShared
swift build --product PKPrompt
swift build --product PositronicKit
swift build --product PKOpenRouterProvider
swift build --product PKOllamaProvider
swift build --product PKOpenAIProvider
swift build --product PKLocalEmbeddings
swift build --product PositronicKitExamples
swift test
```

If a provider remains blocked, replace only that command with a documented expected-exclusion check. The three core product commands and `swift test` are non-negotiable.

Before completion, run on macOS:

```bash
swift build
swift test
swift test --parallel --num-workers 2
```

Linux verification must pass in CI or in a matching Linux container. A macOS-only build is insufficient evidence of completion.

## Suggested Execution Order

1. Add a Linux CI job that initially demonstrates current failures.
2. Remove the macOS-only package assumption and add `FoundationNetworking` imports to all networking sources.
3. Introduce portable and Accelerate vector backends with shared and differential tests.
4. Resolve remaining core compilation failures, including `Observation` or Foundation API differences, with the smallest platform-neutral changes.
5. Move `LocalEmbeddingService` into `PKLocalEmbeddings`, preserving Natural Language behavior on Apple platforms.
6. Add the pinned FastEmbed native bridge and fixed MiniLM implementation for Linux.
7. Build and repair OpenRouter, Ollama, OpenAI, examples, test support, and tests on Linux.
8. Add the README support matrix, embedding portability warning, and manifest Apple-only markers.
9. Add `PKFoundationModelsProvider` as a separately reviewable Apple-only change.
10. Run the full macOS and Linux verification matrix.

## Acceptance Criteria

- [ ] All three core products build and their tests pass on Ubuntu.
- [ ] Every existing optional target has either a passing Linux build or a precise, reproducible blocker documented in the support matrix.
- [ ] No portable source unconditionally imports `Accelerate`, `NaturalLanguage`, or `FoundationModels`.
- [ ] Networking sources compile on Darwin and Linux using conditional `FoundationNetworking` imports.
- [ ] `VectorMath` keeps its public API and selects the native Accelerate backend on supported Apple platforms.
- [ ] Portable vector math is directly tested on macOS and Linux; Accelerate equivalence is tested on macOS.
- [ ] `PKLocalEmbeddings` uses Natural Language on Apple platforms and fixed, in-process FastEmbed/MiniLM inference on Linux.
- [ ] Linux local embedding tests verify 384-dimensional normalized output, deterministic output for a fixture input, batch ordering, initialization failures, and checksum rejection.
- [ ] No provider-backed or out-of-process embedding fallback exists in `PKLocalEmbeddings`.
- [ ] Documentation requires re-embedding when persisted content moves between Apple and Linux.
- [ ] Foundation Models types do not leak into core modules.
- [ ] README and manifest clearly mark Apple-only dependencies and product support.
- [ ] Existing macOS builds and tests remain green.
- [ ] Linux CI is required and green for all products classified as supported.

## Out of Scope

- Replacing Foundation with a third-party compatibility library.
- Vendoring or directly depending on the `swift-foundation` repository.
- Rewriting provider transports that already compile with FoundationNetworking.
- Adding BLAS, LAPACK, or C++ SIMD solely for current vector operations.
- Guaranteeing identical floating-point bit patterns across Accelerate and portable implementations.
- Supporting multiple local embedding models, runtime model selection, or cross-platform-compatible embedding vectors.
- Provider-backed or out-of-process embedding fallbacks.
- Supporting Windows, Android, or WebAssembly in this task.
