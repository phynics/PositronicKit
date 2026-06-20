# Linux Embedding Follow-up Tickets

These tickets close the gaps found while reviewing commit `20462fd`. Execute them in dependency order: **PKFAST-001**, **PKEMBED-002**, **PKCI-003**, then **PKDOC-004**. PKCI-003 may begin in parallel with PKFAST-001, but its MiniLM jobs cannot pass until PKEMBED-002 lands.

## PKFAST-001: Prove a SwiftPM-Compatible In-Process FastEmbed Bridge

**Priority:** P1  
**Type:** Technical spike with working proof  
**Depends on:** None  
**Blocks:** PKEMBED-002

### Summary

Produce a minimal `PKFastEmbed` companion package that Swift can import and execute in-process on Ubuntu x86_64/aarch64 and macOS arm64/x86_64. The current handoff assumes versioned native artifacts, but SwiftPM's standard downloadable binary-target flow is Apple-platform-specific. This ticket must select and prove a distribution mechanism before PositronicKit takes a dependency on it.

### Context

- PositronicKit requires local MiniLM inference on Linux.
- Trait-enabled Apple builds must exercise the same backend.
- Provider APIs and separate local daemons are explicitly excluded.
- The implementation uses `fastembed-rs` with package-pinned `all-MiniLM-L6-v2` model assets.
- PositronicKit must consume an ordinary SwiftPM library product named `PKFastEmbed`.

### Scope

1. Evaluate these supported integration mechanisms:
   - build the Rust library from source through a SwiftPM build-tool plugin;
   - consume a system library through `pkg-config` plus documented installation;
   - publish a SwiftPM-compatible artifact format that demonstrably links on Linux and macOS.
2. Select one mechanism and record the decision in `docs/architecture/PKFASTEMBED_PACKAGING.md`.
3. Create the companion package outside the portable PositronicKit targets. Do not vendor ONNX Runtime or model weights into PositronicKit.
4. Expose a narrow C-compatible bridge with these operations:
   - create a model handle from an absolute model directory;
   - return embedding dimensions;
   - embed one UTF-8 string;
   - embed an ordered batch of UTF-8 strings;
   - destroy the handle;
   - retrieve and free stable error messages.
5. Copy output vectors into Swift-owned memory before returning from the bridge.
6. Pin `fastembed-rs`, ONNX Runtime, tokenizer, model revision, and model-file SHA-256 values.

### Required Tests

- A Swift executable imports `PKFastEmbed` and produces a 384-element vector on Ubuntu x86_64.
- The same executable produces a 384-element vector on macOS arm64.
- Repeated embedding of the same fixture text is deterministic within `1e-6` per element.
- Batch results preserve input order.
- Missing files, checksum mismatch, invalid UTF-8, undersized output buffers, and native initialization failures return errors without leaking or crashing.
- A thread-safety test either proves concurrent calls are supported or documents and enforces serialized access.

### Acceptance Criteria

- [ ] `swift build` succeeds for the companion package on Ubuntu and macOS without manually editing its manifest.
- [ ] `swift test` passes on Ubuntu and macOS.
- [ ] A tagged exact version can be referenced from PositronicKit's `Package.swift`.
- [ ] The selected packaging path works for downstream SwiftPM consumers, not only inside the companion repository.
- [ ] The architecture note explains why the rejected mechanisms were not selected.
- [ ] License notices cover FastEmbed, ONNX Runtime, tokenizer code, and the pinned MiniLM model.

### Verification

```bash
swift build
swift test
swift run PKFastEmbedSmoke /absolute/path/to/pinned-minilm
```

Expected smoke output:

```text
dimensions=384
batch_count=2
normalized=true
```

### Handoff Notes

Do not begin PKEMBED-002 with a mock native package. The result of this ticket must be a real downstream-consumable package and exact version.

---

## PKEMBED-002: Implement MiniLM on Linux and Trait-Enabled Apple Builds

**Priority:** P1  
**Type:** Feature  
**Depends on:** PKFAST-001  
**Blocks:** PKCI-003, PKDOC-004

### Summary

Replace the non-Apple `platformNotSupported` stub with fixed, in-process MiniLM inference. Add the approved additive `MiniLMEmbeddings` SwiftPM trait so macOS can explicitly build and test the same backend while preserving Natural Language as the default Apple implementation.

### Current Problem

- `Sources/PKLocalEmbeddings/LocalEmbeddingService.swift` throws `EmbeddingError.platformNotSupported` whenever Natural Language is unavailable.
- `Tests/PositronicKitTests/EmbeddingServiceTests.swift` currently treats that Linux failure as success.
- `Package.swift` declares Swift tools 6.1 but has no traits or MiniLM backend dependencies.

### Files

- Modify: `Package.swift`
- Modify: `Sources/PKLocalEmbeddings/LocalEmbeddingService.swift`
- Create: `Sources/PKLocalEmbeddings/LocalEmbeddingBackend.swift`
- Create: `Sources/PKLocalEmbeddings/NaturalLanguageEmbeddingBackend.swift`
- Create: `Sources/PKMiniLMLinuxBackend/LinuxMiniLMEmbeddingBackend.swift`
- Create: `Sources/PKMiniLMTraitBackend/TraitMiniLMEmbeddingBackend.swift`
- Create: `Tests/PKLocalEmbeddingsTests/NaturalLanguageEmbeddingTests.swift`
- Create: `Tests/PKLocalEmbeddingsTests/MiniLMEmbeddingContractTests.swift`
- Remove MiniLM/local-embedding cases from: `Tests/PositronicKitTests/EmbeddingServiceTests.swift`

### Public API Contract

```swift
// Apple default build
public init()

// Linux default build
public init(modelDirectory: URL) throws

// Apple build with MiniLMEmbeddings enabled
public init(miniLMModelDirectory: URL) throws

public func generateEmbedding(for text: String) async throws -> [Float]
public func generateEmbeddings(for texts: [String]) async throws -> [[Float]]
```

`LocalEmbeddingService()` must continue to select Natural Language on Apple platforms even when `MiniLMEmbeddings` is enabled. MiniLM construction on Apple must always be explicit.

### Implementation Requirements

1. Add this non-default package trait:

```swift
traits: [
    .trait(
        name: "MiniLMEmbeddings",
        description: "Build the in-process MiniLM embedding backend on Apple platforms."
    ),
]
```

2. Add the exact PKFAST-001 package version and conditional package-private backend targets defined in the approved handoff.
3. Ensure a default Apple build neither builds nor links `PKFastEmbed`.
4. Verify model and tokenizer files against hard-coded SHA-256 values before native initialization.
5. Serialize native calls if PKFAST-001 does not prove the handle is safe for concurrent access.
6. Remove `EmbeddingError.platformNotSupported` if it has no remaining reachable use.
7. Do not introduce provider fallback, a model registry, runtime model selection, or cross-platform vector compatibility.

### Required Tests

- Linux and trait-enabled macOS return normalized 384-element vectors.
- Single and batch APIs use identical ordering and normalization behavior.
- Same input and pinned assets produce deterministic results within `1e-6` per element on the same platform/backend.
- Missing model directory, missing files, checksum mismatch, and native initialization failure map to stable `EmbeddingError` cases.
- Default Apple construction uses Natural Language.
- Trait-enabled Apple explicit construction uses MiniLM, verified through a package-access test identifier rather than output dimensions alone.
- Linux tests fail if the implementation regresses to `platformNotSupported`.

### Acceptance Criteria

- [ ] `swift package show-traits` lists `MiniLMEmbeddings` and it is disabled by default.
- [ ] `swift build --product PKLocalEmbeddings` succeeds on Linux and provides working MiniLM inference.
- [ ] `swift test --filter MiniLMEmbeddingContractTests` passes on Linux.
- [ ] Default macOS tests pass without building or linking `PKFastEmbed`.
- [ ] `swift test --traits MiniLMEmbeddings --filter MiniLMEmbeddingContractTests` passes on macOS.
- [ ] The non-Apple test expecting `platformNotSupported` is deleted.
- [ ] No concrete embedding implementation returns to the core `PositronicKit` target.

### Verification

```bash
swift package show-traits
swift test
swift build --product PKLocalEmbeddings --traits MiniLMEmbeddings
swift test --traits MiniLMEmbeddings --filter MiniLMEmbeddingContractTests
```

---

## PKCI-003: Test the Minimum Swift Toolchain and Every Embedding Configuration

**Priority:** P2  
**Type:** CI hardening  
**Depends on:** PKEMBED-002 for MiniLM jobs; minimum-toolchain work can start independently  
**Blocks:** PKDOC-004

### Summary

Make CI validate the package's declared Swift 6.1 minimum and all supported local-embedding build configurations. The current Linux job only uses Swift 6.3.2, which can hide accidental dependencies on APIs newer than the manifest minimum.

### Files

- Modify: `.github/workflows/ci.yml`
- Modify only if compatibility defects are found: `Package.swift`, affected sources, and focused tests

### Required CI Matrix

1. **Minimum Linux:** Ubuntu 24.04 with Swift 6.1.3.
2. **Current Linux:** Ubuntu 24.04 with Swift 6.3.2.
3. **Default macOS:** repository's supported Xcode, no traits.
4. **MiniLM macOS:** same Xcode with `MiniLMEmbeddings` enabled and cached pinned model assets.

### Commands

Minimum and current Linux jobs must run:

```bash
swift build --product PKShared
swift build --product PKPrompt
swift build --product PositronicKit
swift build --product PKLocalEmbeddings
swift build --product PKOpenRouterProvider
swift build --product PKOllamaProvider
swift build --product PKOpenAIProvider
swift build --product PositronicKitExamples
swift test
```

The MiniLM macOS job must run:

```bash
swift build --product PKLocalEmbeddings --traits MiniLMEmbeddings
swift test --traits MiniLMEmbeddings --filter MiniLMEmbeddingContractTests
```

The default macOS job retains:

```bash
swift build
swift test
swift test --parallel --num-workers 2
swift package clean
swift build -v --product PKLocalEmbeddings 2>&1 | tee default-apple-build.log
if rg '(-lPKFastEmbed|PKFastEmbed\\.(framework|a))' default-apple-build.log; then exit 1; fi
```

### Acceptance Criteria

- [ ] Swift 6.1.3 and Swift 6.3.2 Linux jobs both pass.
- [ ] Every product classified as Linux-supported has an explicit build command.
- [ ] Linux local-embedding tests perform real inference; they do not assert an unsupported-platform error.
- [ ] Default macOS CI proves `PKFastEmbed` is absent from the linked product.
- [ ] Trait-enabled macOS CI runs the MiniLM contract suite.
- [ ] Model cache keys include the exact model SHA-256 so stale assets cannot be reused.
- [ ] Required branch protection includes the minimum Linux, current Linux, default macOS, and MiniLM macOS jobs.

### Verification

Open or update a pull request and confirm all four required job classes complete successfully. Record links to the successful runs in the ticket before closing it.

---

## PKDOC-004: Publish the Final Platform and Embedding Support Contract

**Priority:** P2  
**Type:** Documentation  
**Depends on:** PKEMBED-002, PKCI-003  
**Blocks:** None

### Summary

Update public documentation after real Linux and trait-enabled macOS verification exists. Remove provisional labels and document model provisioning, trait usage, and the requirement to rebuild embeddings when moving persisted content between Apple and Linux.

### Files

- Modify: `README.md`
- Modify: `Sources/PositronicKit/README.md` if it contains setup guidance affected by the product split
- Modify: `docs/superpowers/specs/2026-06-19-linux-swift-foundation-handoff.md` only to mark completed decisions, not to rewrite history

### Required Documentation

- Product support matrix backed by passing CI rather than "portable candidate" labels.
- `PKLocalEmbeddings` installation and imports.
- Apple default Natural Language example.
- Linux `LocalEmbeddingService(modelDirectory:)` example.
- Apple `MiniLMEmbeddings` trait declaration and `LocalEmbeddingService(miniLMModelDirectory:)` example.
- Exact model asset filenames, revision, checksums, and host-owned cache responsibility.
- Clear statement that Apple Natural Language and MiniLM vectors cannot share a similarity index.
- Migration instruction: copy source content, then rebuild embeddings on the destination platform.
- Explicit statement that no provider or daemon fallback is used.

### Acceptance Criteria

- [ ] Every README command is exercised in CI or a compiled documentation test.
- [ ] Support labels match the required CI jobs from PKCI-003.
- [ ] No documentation describes `swift-foundation` as an application package dependency.
- [ ] No documentation promises multi-model selection or cross-platform-compatible vectors.
- [ ] The public source migration from `PositronicKit.LocalEmbeddingService` to `PKLocalEmbeddings.LocalEmbeddingService` is called out.

### Verification

```bash
swift build
swift test
rg -n "portable candidate|platformNotSupported|provider fallback" README.md Sources/PositronicKit/README.md
```

Expected: build and tests pass; the search returns no stale support claims except text explicitly explaining that provider fallback is not supported.
