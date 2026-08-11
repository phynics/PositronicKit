# PositronicKit

PositronicKit is a high-performance, developer-friendly Swift toolkit for building production-ready AI agents. Built from the ground up for the Swift 6 concurrency era, it provides transport-neutral runtime orchestration, a structured prompt composition DSL, and clean, pluggable contracts—without locking you into a specific networking, hosting, or provider model.

See [CHANGELOG.md](CHANGELOG.md) for release notes and tagged compatibility history, and [docs/Releasing.md](docs/Releasing.md) for the release workflow.

## Key Strengths

*   **SwiftUI-Style Declarative Prompts (`PKPrompt`):** Author complex prompts as structured trees using a familiar body-composition DSL. Enjoy automatic modifier inheritance for properties like `.priority(...)`, `.cachePolicy(...)`, and `.compression(...)`.
*   **Smart Context Caching (Prompt Journaling):** Dynamic prompt tracking with `PromptJournal` automatically computes stable prefixes and volatile/semi-stable overlays. This minimizes LLM latency and API costs by maximizing prompt cache hit rates.
*   **Zero-Latency Auxiliary Tasks (Sidecar Directives):** Fetch parallel metadata (e.g., conversation titles, sentiment classification, summaries) piggy-backed on the *same single LLM request* as the user-visible response. The user sees a standard streamed response, while directives stream or buffer in the background with zero extra round-trips.
*   **Swift 6 Structured Concurrency & Actor Isolation:** Fully thread-safe runtime architecture leveraging Swift 6 actors and structured concurrency. Composable execution stages guarantee resource cleanup (e.g., persisting telemetry, closing resources) even on failures.
*   **Completely Pluggable & Decoupled:** Downstream independence is a core invariant. Easily swap persistence engines, custom tool routers, and workspace resolvers. Supports Anthropic, OpenAI, Ollama, and OpenRouter out of the box with zero runtime dependencies.
*   **First-Class Linux Support:** Built to compile and test seamlessly on both Apple platforms and Linux (via bare Swift 6 toolchain, with an optimized Rust bridge for local MiniLM embeddings).

---

## Quick Start

Add PositronicKit as a Swift Package dependency:

```swift
.package(url: "https://github.com/phynics/PositronicKit.git", from: "3.4.0")
```

Public products follow semver: patch releases preserve source compatibility, minor releases add functionality compatibly, and breaking API changes require a new major version.

Import the modules you need:

```swift
import PositronicKit    // runtime orchestration
import PKPrompt         // prompt composition
import PKShared         // shared contracts
import PKLocalEmbeddings // optional local embeddings facade
import PKOpenAIProvider  // optional concrete provider
```

Convenience runtime initializers like `PositronicKit(openAIKey:)` or `PositronicKit(ollamaModel:)` live in the matching provider target, not in the core `PositronicKit` module.

Choose the smallest operation tier that fits the feature:

```swift
let kit = PositronicKit(languageModel: myLLM)
let answer = try await kit.complete("Summarize this note.")       // tier 1: one-shot
let timeline = try await kit.timelineManager.createTimeline()
let driver = kit.openTimeline(timeline.id)                        // tier 2: TimelineDriver
let timelineManager = kit.timelineManager                          // tier 3: timelines
let agent = kit.agenticRuntime(                                     // tier 4: agent loop
    timelineID: driver.timelineID,
    agentInstanceID: UUID()
)
let tools = kit.toolRouter                                         // tier 5: raw primitives
```

### Facade readiness, validation, and error delivery

`await kit.isLanguageModelConfigured` is a live, read-only configuration-readiness signal from
the injected language model. It does not expose credentials or provider configuration, and it is
not a connectivity probe or a guarantee that a later request will succeed. Treat `run`, `stream`,
or `complete` as the authoritative operation because model state can change after the check.

`run(_:)` validates `ChatRunRequest.maxTurns` before timeline resolution, persistence, or provider
work; values below `1` throw `ChatRunError.invalidMaxTurns` directly from the awaited `run` call.
When `agentInstanceID` is present, the runtime resolves that agent once after timeline resolution
and before provider readiness or input persistence. The default `.failRequired` degradation policy
throws `AgentInstanceError.instanceNotFound`; `.continueWithWarnings` proceeds without the missing
agent and includes an agent diagnostic in the initial generation-context event. A failed preflight
does not consume `sendID`, so the same identifier can be retried after the dependency is repaired.

One-shot text, result, stream, and structured-output calls all accept per-call generation
parameters and an inactivity timeout on their configurable overloads. Per-call parameters override
the facade defaults; `nil` uses those defaults. `idleTimeout` defaults to 60 seconds and resets
after every provider chunk. Structured one-shot output uses the same native-response-format or
synthetic-tool adapter path as full runs:

```swift
let json = try await kit.complete(
    "Extract the project metadata.",
    structuredOutput: request,
    generationParameters: GenerationParameters(temperature: 0),
    idleTimeout: 30
)
```

Errors arrive at the boundary where the work occurs:

- Request and preparation failures—invalid `maxTurns`, timeline hydration, required-agent
  preflight, provider configuration, sidecar validation, and input/history preparation—throw from
  `try await kit.run(request)` before a stream is returned.
- Provider and pipeline failures after `run(_:)` returns arrive by throwing while the returned
  stream is iterated. A foreign provider failure retains its original causal error and exposes the
  stable LLM identity `PKErrorDomain.llm` / `1005` through
  `ChatEvent.ErrorIdentity.extracting(from:)`, even when nested in a pipeline error.
- `complete` and `completeResult` consume their stream internally, so preparation and provider
  failures both throw from the one-shot call. `stream` returns immediately and reports provider
  failures during iteration.

Cancelling a task that consumes a facade run cancels its provider work and releases the timeline's
active-task registration. Abandoning a facade `stream` iterator likewise cancels the provider;
cancelling `complete` or `completeResult` surfaces `CancellationError` without foreign-error
wrapping.

In an application, hold `kit` in an app-owned `Service` class and pass the managers or
controllers it vends to the subsystems that use them.

## Documentation

Detailed documentation has been split into focused guides:

- **[Setup Guide](docs/Setup.md)**: Configuration, logging, required services, and choosing your entry point.
- **[Usage Guide](docs/Usage.md)**: Managing agents, pipelines, and local embeddings.
- **[Architecture](docs/Architecture.md)**: Core concepts, state management, and the v1 extension point registry.
- **[Prompt Composition](docs/PKPromptComposition.md)**: Authoring models, caching, and prompt journaling.
- **[Sidecar Directives](docs/SidecarDirectives.md)**: Requesting auxiliary generations piggy-backed on the same LLM request.

## Code Examples

All snippets below are compiled as part of `PositronicKitExamples`.

### Prompt composition with PKPrompt

Author prompts as structured trees, then assemble and render them into validated sections.

```swift
import PKPrompt

let prompt = AnyPrompt.build {
    SystemPrompt("You are helping with project tooling.")
    TextPrompt("- build\n- test\n- lint", id: "tools")
        .compression(.summarize)
        .cachePolicy(.semiStable)
    UserPrompt("Recommend the safest next step.")
}

let assembled = try prompt.assemblePrompt()
let rendered = await assembled.render()

print(rendered.sections.map(\.id))
```

### Sidecar directives (piggy-backed auxiliary generations)

Get a conversation title, tone marker, or summary from the same request as the user-visible response.

```swift
import JSONSchemaBuilder
import PKShared
import PositronicKit

let title = SidecarDirective(
    name: "title",
    instruction: "A short conversation title (3-6 words). Return null if the conversation already has a good title.",
    schema: JSONString().definition(),
    streaming: .buffered
)

let stream = try await chat.run(.init(
    timelineID: timelineId,
    message: "What's the deal with actors in Swift 6?",
    sidecars: [title]
))

for try await event in stream {
    if let text = event.textContent {
        print(text, terminator: "")
    }
    if let result = event.sidecarResults?.first(where: { $0.name == "title" }) {
        switch result.outcome {
        case let .value(value): print("title: \(value)")
        case .declined: print("title: declined")
        case let .failed(reason): print("title failed: \(reason)")
        }
    }
}
```

### Prompt journaling across snapshots

Stable sections persist across turns; semi-stable changes become overlays; volatile sections are replaced each turn. This lets providers reuse a long prefix while only paying for the updated slices.

```swift
import PKPrompt

struct AvailableTool: Sendable {
    let id: String
    let summary: String
}

func render(tools: [AvailableTool], query: String) async throws -> RenderedPrompt {
    try await AnyPrompt.build {
        SystemPrompt("You are a helpful coding assistant.")
        ForEach(tools) { tool in
            TextPrompt(tool.summary, id: "tool-\(tool.id)")
                .cachePolicy(.semiStable)
        }
        UserPrompt(query)
            .cachePolicy(.volatile)
    }.assemblePrompt().render()
}

var journal = PromptJournal()

let first = try await render(tools: [
    .init(id: "build", summary: "Builds the package."),
    .init(id: "test", summary: "Runs tests."),
], query: "What should I run first?")

let second = try await render(tools: [
    .init(id: "build", summary: "Builds the package."),
    .init(id: "test", summary: "Runs the full test suite."),
    .init(id: "lint", summary: "Checks formatting and style."),
], query: "What should I run first?")

let initialPlan = try journal.observe(first)
print(initialPlan.baseSections.map(\.section.id))
// ["system", "tool-build", "tool-test"]
print(initialPlan.overlaySections.isEmpty)
// true — nothing has changed yet

let updatedPlan = try journal.observe(second)
print(updatedPlan.baseSections.map(\.section.id))
// ["system", "tool-build", "tool-test"] — unchanged stable prefix stays materialized
print(updatedPlan.overlaySections.map(\.section.id))
// ["tool-test", "tool-lint"] — only the modified / new semi-stable sections

for overlay in updatedPlan.overlaySections {
    if case let .text(text) = overlay.section.content {
        print("\(overlay.section.id): \(text)")
    }
}
// tool-test: Runs the full test suite.
// tool-lint: Checks formatting and style.

let compactedPlan = journal.compact()
print(compactedPlan?.baseSections.map(\.section.id) ?? [])
// ["system", "tool-build", "tool-test", "tool-lint"] — overlays folded back into base
print(compactedPlan?.overlaySections.isEmpty ?? false)
// true
```

### How Overlays are Represented in the LLM Context

Under the hood, `PromptJournalPlan` renders these state transitions into provider-neutral conversation messages using a set of structured XML tags. This allows the LLM to cleanly track how sections evolve without having to resend unchanged stable blocks:

*   **Snapshot Mode (`.snapshot`):** Emitted at the beginning of a session, establishing the initial state of the prompt's baseline sections:
    ```xml
    <prompt_journal_snapshot id="tool-build" path="tool-build">
    Builds the package.
    </prompt_journal_snapshot>
    ```
*   **Delta Mode (`.delta`):** When semi-stable sections change, the journal appends only the difference messages to the conversation context:
    *   **Additions:** Wrapped in `<prompt_journal_add>` tags.
    *   **Modifications:** Wrapped in `<prompt_journal_replace>` tags.
    *   **Removals:** Specified as `<prompt_journal_remove id="..." />`.

For example, when `updatedPlan` above is built into messages, the changes are appended at the end of the context as:
```xml
<prompt_journal_replace id="tool-test" path="tool-test">
Runs the full test suite.
</prompt_journal_replace>

<prompt_journal_add id="tool-lint" path="tool-lint">
Checks formatting and style.
</prompt_journal_add>
```
Once `journal.compact()` is called, these delta operations are merged directly back into the baseline snapshot for subsequent turns.

## Testing downstream with PKTestSupport

`PKTestSupport` is a public library product for downstream test targets. Import it normally—never
with `@testable`—to use its mocks, fixtures, stream factories, and `TestRuntime` composition root.

> Release availability: the hardened concurrency and capture-history contracts described below
> are currently listed under [Unreleased](CHANGELOG.md#unreleased); they are not present in the
> `3.4.0` tag used in Quick Start. Semver-pinned consumers should adopt them only after a release
> containing that changelog entry is tagged. Use a local-path override only while developing a
> coordinated unreleased change, as described in [Releasing](docs/Releasing.md#downstream-cadence).

This example compiles in an ordinary downstream test target with `PKShared`, `PositronicKit`, and
`PKTestSupport` product dependencies. It uses the single-response fallback deliberately; scripted
queues are covered separately below.

```swift
import PKShared
import PKTestSupport
import PositronicKit
import Testing

@Test("captures a complete downstream request")
func capturesDownstreamRequest() async throws {
    let llm = MockLLMService()
    llm.mockClient.nextResponse = "ok"

    let stream = await llm.chatStream(
        messages: [LLMMessage(role: .user, content: "hello")],
        tools: nil,
        toolChoice: nil,
        responseFormat: .text,
        generationParameters: GenerationParameters(temperature: 0.2),
        modelTier: .fast
    )
    _ = try await stream.collect()

    #expect(llm.chatCaptureHistory.count == 1)
    #expect(llm.chatCaptureHistory.last?.messages.first?.content == "hello")
    #expect(llm.chatCaptureHistory.last?.modelTier == .fast)
}
```

The harness contracts are intentionally explicit:

- `MockLLMClient` chooses one stream plan atomically in this precedence order: configured
  never-finishing call index, configured error, one raw-chunk script, one text-chunk script, one
  queued full response, then `nextResponse`. A normal text plan consumes at most one queued
  `nextToolCalls` entry; error, never-finishing, and raw plans do not consume it. FIFO scripts are
  assigned in mutex-admission order. With concurrent callers, do not infer a mapping from task
  creation order to queue position.
- Capture histories are complete atomic snapshots. `MockLLMClient` records chat and send requests
  before surfacing injected errors; `MockLLMService` records low-level captures and model tiers
  before returning `stubbedStream`, and records full context requests before delegation. Legacy
  `last…` properties remain convenience views of the latest capture.
- `MockLLMService` starts configured with `.openAI`. `updateConfiguration` and successful
  `importConfiguration` mark it configured; `clearConfiguration` resets to `.openAI` and marks it
  unconfigured. Export/import performs a real JSON round trip. `loadConfiguration` and
  `restoreFromBackup` remain no-op test hooks.
- `MockLLMClient(clock:)` drives `nextStreamWait` through the injected clock before each finite
  raw or text chunk. Terminating those streams cancels their producer task; cancellation is checked
  around each clock sleep. The mock never holds its mutex while sleeping, yielding, encoding,
  decoding, delegating, or invoking a callback.
- Memory, embedding, LLM, and persistence states use mutex-protected snapshots or atomic
  read/modify/write operations. `BatchFailingMessageStore` increments its count and decides
  threshold admission together, and composite request-origin callbacks are snapshotted under lock
  then awaited after unlocking.
- `TestWorkspace` creates a unique directory and removes it best-effort on deinitialization. Retain
  the `TestWorkspace` object—not only its `root` URL—for the entire time the directory is needed.
- `TestRuntime.timelineManager`, `toolRouter`, and `agentInstanceManager` are the exact
  facade-owned instances; in particular,
  `runtime.agentInstanceManager === runtime.positronicKit.agentInstanceManager`.
  `agentWorkspaceService` and `workspaceManager` remain separate compatibility helpers backed by
  the runtime's supplied persistence and workspace factory.

## Package Layout

Core modules:

- **PositronicKit** — the runtime layer: chat engine, orchestration stages, tool routing, timeline and workspace management, and provider-neutral LLM orchestration.
- **PKPrompt** — the prompt layer: a SwiftUI-style `@PromptBuilder` DSL, structured compression, cache-aware assembly, and prompt journaling for stable-prefix workflows.
- **PKShared** — the contract layer: API models, tool protocols, provider contracts, error types, structured logging, and shared utilities.
- **PKLocalEmbeddings** — the platform-local embedding facade (`LocalEmbeddingService`). Apple uses Natural Language by default; Linux uses the host-provisioned MiniLM backend.

Provider targets ship separately so you opt in only to the integrations you want:

- **PKOpenAIProvider**, **PKOpenRouterProvider**, **PKOllamaProvider**, **PKAnthropicProvider**, **PKFoundationModelsProvider** — concrete adapters plus convenience registration APIs. `PKAnthropicProvider` speaks the Anthropic Messages API natively (event-based SSE, `input_schema` tools, top-level `system` param); structured output uses the forced synthetic-tool path since the API has no `response_format`.

Supporting targets:

- **PKObservable** — opt-in `@Observable` wrappers for UI-facing consumers; `TimelineController` mirrors `TimelineDriver` streaming state for SwiftUI clients.
- **PositronicKitExamples** — runnable examples that double as living documentation.
- **PKTestSupport** — shared mocks, fixtures, and test helpers for downstream test targets.

All products are supported on Apple platforms and Linux (see [Verification](#verification) for the gates that cover each).

## Verification

Build and test with standard SwiftPM commands (`swift build`, `swift test`, `swift run PositronicKitExamples`). Full verification runs through the root Makefile:

```bash
make verify            # Default build, docs, linkage audit, and tests (macOS)
make verify-linux      # Bootstrap pinned assets/native bridge and run the full Linux test suite
make verify-linux-asan # PKFastEmbed bridge tests under Linux x86_64 AddressSanitizer (bridge-only)
make verify-products   # Build every supported product on the current host
make verify-minilm     # Bootstrap pinned assets/native bridge and run MiniLM tests
```

`make verify-linux` needs a Rust toolchain, a C/C++ toolchain, `pkg-config`, OpenSSL development headers, `curl`, and `shasum` in addition to Swift — see [`AGENTS.md`](AGENTS.md#linux-development-setup) for details.

`make verify-minilm` downloads the pinned Hugging Face model assets on first use, validates their checksums, builds the Rust bridge, and stores the native prefix and model under `.build`. Override the locations with `PKFASTEMBED_PREFIX=...` and `PK_MINILM_MODEL_DIR=...`. `make verify-linux-asan` requires nightly Rust plus `rust-src` and scopes to `native/pkfastembed` only.

## Linux Development

PositronicKit supports Linux development through two paths: a Docker-based workflow (recommended for macOS hosts) and a bare-toolchain approach.

### Docker

The included Dev Container provides Swift 6.3.3, Rust stable, and all native prerequisites on Ubuntu 24.04:

```bash
make linux-image   # Build the development image (swift:6.3.3-noble + Rust + native deps)
make linux-build   # Compile in the container (bind-mounts your checkout)
make linux-test    # Run the full Linux gate: make verify-linux-current
```

Open the project in VS Code with the Dev Containers extension for a full IDE experience, or use the Make targets from any terminal with Docker installed. The container bind-mounts your checkout at `/workspace`; build artifacts land in the host `.build/` directory.

### Bare toolchain

Alternatively, install the prerequisites directly on your Linux host — see [`AGENTS.md`](AGENTS.md#linux-development-setup) for the full dependency list. Once installed, the canonical gate is:

```bash
make verify-linux-current
```

## Companion App

[`Yakamoz`](https://github.com/phynics/Yakamoz) is the native macOS showcase app for PositronicKit. It drives the runtime from a SwiftUI chat client and exposes the prompt pipeline, sent provider payloads, prompt journal, response metadata, tool traces, and local workspace state through an inspector drawer.
