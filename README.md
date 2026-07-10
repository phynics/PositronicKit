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
.package(url: "https://github.com/phynics/PositronicKit.git", from: "1.0.0")
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
let kit = PositronicKit(llmService: myLLM)
let answer = try await kit.complete("Summarize this note.")       // tier 1: one-shot
let conversation = try await kit.newConversation()                // tier 2: Conversation
let timelineManager = kit.timelineManager                          // tier 3: timelines
let agent = kit.agenticRuntime(                                     // tier 4: agent loop
    timelineId: conversation.timelineId,
    agentInstanceId: UUID()
)
let tools = kit.toolRouter                                         // tier 5: raw primitives
```

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
    timelineId: timelineId,
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
        ForEach(data: tools) { tool in
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

let initialPlan = journal.observe(first)
print(initialPlan.baseSections.map(\.section.id))
// ["system", "tool-build", "tool-test"]
print(initialPlan.overlaySections.isEmpty)
// true — nothing has changed yet

let updatedPlan = journal.observe(second)
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

## Package Layout

Core modules:

- **PositronicKit** — the runtime layer: chat engine, orchestration stages, tool routing, timeline and workspace management, and provider-neutral LLM orchestration.
- **PKPrompt** — the prompt layer: a SwiftUI-style `@PromptBuilder` DSL, structured compression, cache-aware assembly, and prompt journaling for stable-prefix workflows.
- **PKShared** — the contract layer: API models, tool protocols, provider contracts, error types, structured logging, and shared utilities.
- **PKLocalEmbeddings** — the platform-local embedding facade (`LocalEmbeddingService`). Apple uses Natural Language by default; Linux uses the host-provisioned MiniLM backend.

Provider targets ship separately so you opt in only to the integrations you want:

- **PKOpenAIProvider**, **PKOpenRouterProvider**, **PKOllamaProvider**, **PKAnthropicProvider**, **PKFoundationModelsProvider** — concrete adapters plus convenience registration APIs. `PKAnthropicProvider` speaks the Anthropic Messages API natively (event-based SSE, `input_schema` tools, top-level `system` param); structured output uses the forced synthetic-tool path since the API has no `response_format`.

Supporting targets:

- **PKObservable** — opt-in `@Observable` wrappers for UI-facing consumers; `ObservableConversation` mirrors `Conversation` streaming state for SwiftUI clients.
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

## Companion App

[`Yakamoz`](https://github.com/phynics/Yakamoz) is the native macOS showcase app for PositronicKit. It drives the runtime from a SwiftUI chat client and exposes the prompt pipeline, sent provider payloads, prompt journal, response metadata, tool traces, and local workspace state through an inspector drawer.
