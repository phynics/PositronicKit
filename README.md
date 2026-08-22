# PositronicKit

PositronicKit is an embeddable Swift runtime for agentic application features. It combines
transport-neutral orchestration, structured prompt composition, provider-neutral contracts, and
injectable Workspace and persistence boundaries.

See [CHANGELOG.md](CHANGELOG.md) for release notes and tagged compatibility history, and [docs/Releasing.md](docs/Releasing.md) for the release workflow.

## Choose a documentation channel

- Latest stable: `4.0.0`. Use the [immutable tagged documentation](https://github.com/phynics/PositronicKit/blob/4.0.0/README.md) and the semver dependency below for production.
- Next: this `main` README and the [Next documentation landing](docs/next/) describe unreleased follow-up work. Use a branch or local-path dependency only for coordinated evaluation.

The [documentation landing](docs/) defaults to stable and keeps stable links separate from the
Next channel.

## Key Strengths

*   **SwiftUI-Style Declarative Prompts (`PKPrompt`):** Author complex prompts as structured trees using a familiar body-composition DSL. Enjoy automatic modifier inheritance for properties like `.priority(...)`, `.cachePolicy(...)`, and `.compression(...)`.
*   **Smart Context Caching (Prompt Journaling):** Dynamic prompt tracking with `PromptJournal` automatically computes stable prefixes and volatile/semi-stable overlays. This minimizes LLM latency and API costs by maximizing prompt cache hit rates.
*   **Zero-Latency Auxiliary Tasks (Sidecar Directives):** Fetch parallel metadata (e.g., thread titles, sentiment classification, summaries) piggy-backed on the *same single LLM request* as the user-visible response. The user sees a standard streamed response, while directives stream or buffer in the background with zero extra round-trips.
*   **Swift 6 Structured Concurrency & Actor Isolation:** Fully thread-safe runtime architecture leveraging Swift 6 actors and structured concurrency. Composable execution stages guarantee resource cleanup (e.g., persisting telemetry, closing resources) even on failures.
*   **Completely Pluggable & Decoupled:** Downstream independence is a core invariant. Easily swap persistence engines, custom tool routers, and workspace resolvers. Supports Anthropic, OpenAI, Ollama, and OpenRouter out of the box with zero runtime dependencies.
*   **First-Class Linux Support:** Built to compile and test seamlessly on both Apple platforms and Linux via the pinned Swift/Podman development path.

---

## Stable package dependency

Add PositronicKit as a Swift Package dependency:

```swift
.package(url: "https://github.com/phynics/PositronicKit.git", from: "4.0.0")
```

Public products follow semver. Continue with the tagged README for stable API examples. The
examples below describe the current Next public story and may advance beyond `4.0.0`.

## Next / v4 quick start

Import the modules you need:

```swift
import PositronicKit    // runtime orchestration
import PKPrompt         // prompt composition
import PKContracts       // shared contracts
import PKOpenAIProvider  // optional concrete provider
```

Convenience runtime initializers like `PositronicKit(openAIKey:)` or `PositronicKit(ollamaModel:)` live in the matching provider target, not in the core `PositronicKit` module.

Choose the smallest operation tier that fits the feature:

```swift
let kit = PositronicKit(languageModel: myLLM)
let answer = try await kit.model.generate("Summarize this note.") // tier 1: raw model
let thread = try await kit.threads.create()                        // tier 2: durable Thread
let turn = try await thread.startDirectTurn(                      // tier 3: explicit direct Turn
    message: "Continue the summary.",
    context: DirectTurnContext(systemInstructions: "", contributor: .host)
)
let stream = turn.events()
let agent = try await kit.agents.create(                            // tier 4: managed identity
    name: "Researcher",
    description: "Summarizes source material."
)
try await kit.agents.attach(agent.id, to: thread.id)
let managedTurn = try await thread.startTurn(message: "Use the attached identity.")
let managedStream = managedTurn.events()
let workspaces = try await kit.workspaces.list()                    // tier 5: workspace catalog
```

The capability values are the supported consumer entry points. `kit.model` is thread-free
inference; `kit.threads` returns a stateful `ThreadHandle`; `kit.agents` manages identities and
their Thread attachments; and `kit.workspaces` owns the workspace catalog. Concrete managers,
task registries, and the turn pipeline are facade implementation details.

Managed Turns capture typed Agent continuity at admission through `AgentContextSource`. The
bundled filesystem source reads the Agent primary Workspace's `Notes/` files; inject a source in
`RuntimeConfiguration.customization` for database-backed, remote, or deliberately memory-free
Agents. The same customization value can supply bounded `TurnContextSource` notes and
best-effort `AgentActivitySink`/post-terminal `TurnOutcomeSink` integrations. Use
`kit.agents.retire` to drain an identity and `kit.agents.purge` only after retirement.

### Facade readiness, validation, and error delivery

`await kit.model.isConfigured` is a live, read-only configuration-readiness signal from the
injected language model. It does not expose credentials or provider configuration, and it is not
a connectivity probe or a guarantee that a later request will succeed. Treat `ThreadHandle.run`,
`kit.model.stream`, or `kit.model.generate` as authoritative because model state can change after
the check.

`ThreadHandle.startTurn(_:)` validates the request and captures the Agent from durable Thread
attachment state. A detached Thread uses `startDirectTurn(message:context:)`, where the caller
supplies the complete system prompt (including an intentional empty prompt) and contributors.
Both return a `TurnHandle`: `events()` is a nonthrowing future-event stream, `outcome()` replays
the durable terminal result, and `cancel()` targets exactly that Turn. Use the advanced managed
`run(_:)` request-shaped seam for options such as sidecars.

One-shot text, result, stream, and structured-output calls all accept per-call generation
parameters and an inactivity timeout on their configurable overloads. Per-call parameters override
the facade defaults; `nil` uses those defaults. `idleTimeout` defaults to 60 seconds and resets
after every provider chunk. Structured one-shot output uses the same native-response-format or
synthetic-tool adapter path as full runs:

```swift
let json = try await kit.model.generateStructured(
    "Extract the project metadata.",
    structuredOutput: request,
    generationParameters: GenerationParameters(temperature: 0),
    idleTimeout: 30
)
```

Errors arrive at the boundary where the work occurs:

- Request and preparation failures—invalid `maxModelRounds`, Thread hydration, required-Agent
  preflight, provider configuration, sidecar validation, and input/history preparation—throw from
  `try await kit.threads.open(threadID).run(request)` before a stream is returned.
- Provider and pipeline failures after a `TurnHandle` is admitted arrive as terminal events on
  its nonthrowing `events()` stream. The durable `outcome()` remains authoritative for every
  joiner; advanced `ThreadHandle.run(_:)` retains the throwing stream contract for request-shaped
  options.
- `kit.model.generate` and `generateStructured` consume provider streams internally, so preparation
  and provider failures both throw from the one-shot call. `kit.model.stream` returns immediately
  and reports provider failures during iteration.

Cancelling a task that consumes a facade run cancels its provider work and releases the thread's
active-task registration. Abandoning a facade `stream` iterator likewise cancels the provider;
cancelling `complete` or `completeResult` surfaces `CancellationError` without foreign-error
wrapping.

In an application, hold `kit` in an app-owned `Service` class and pass the capability values or
handles it vends to the subsystems that use them.

## Documentation

Detailed documentation has been split into focused guides:

- **[Setup Guide](docs/Setup.md)**: Configuration, logging, required services, and choosing your entry point.
- **[Usage Guide](docs/Usage.md)**: Managed and direct Turns, Agents, and Workspaces.
- **[Architecture](docs/Architecture.md)**: v4 domain boundaries, capability values, durability, and execution authority.
- **[Development](docs/Development.md)**: Contributor platform setup and Linux/Podman gates.
- **[Context map](CONTEXT-MAP.md)**: Canonical v4 vocabulary and ownership boundaries.
- **[Architecture decisions](docs/adr/)**: Accepted v4 decisions and their trade-offs.
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

Get a thread title, tone marker, or summary from the same request as the user-visible response.

```swift
import JSONSchemaBuilder
import PKContracts
import PositronicKit

let title = SidecarDirective(
    name: "title",
    instruction: "A short thread title (3-6 words). Return null if the thread already has a good title.",
    schema: JSONString().definition(),
    streaming: .buffered
)

let stream = try await kit.threads.open(threadID).run(.init(
    threadID: threadID,
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

Under the hood, `PromptJournalPlan` renders these state transitions into provider-neutral thread messages using a set of structured XML tags. This allows the LLM to cleanly track how sections evolve without having to resend unchanged stable blocks:

*   **Snapshot Mode (`.snapshot`):** Emitted at the beginning of a session, establishing the initial state of the prompt's baseline sections:
    ```xml
    <prompt_journal_snapshot id="tool-build" path="tool-build">
    Builds the package.
    </prompt_journal_snapshot>
    ```
*   **Delta Mode (`.delta`):** When semi-stable sections change, the journal appends only the difference messages to the thread context:
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

> Release availability: this section documents the current Next channel. It is not part of the stable `4.0.0`
> channel. Use a local-path override only for coordinated unreleased work, as described in
> [Releasing](docs/Releasing.md#downstream-cadence).

This example compiles in an ordinary downstream test target with `PKContracts`, `PositronicKit`, and
`PKTestSupport` product dependencies. It uses the single-response fallback deliberately; scripted
queues are covered separately below.

```swift
import PKContracts
import PKTestSupport
import PositronicKit
import Testing

@Test("captures a complete downstream request")
func capturesDownstreamRequest() async throws {
    let llm = MockLLMService()
    llm.mockClient.nextResponse = "ok"

    let stream = await llm.generationStream(
        messages: [LLMMessage(role: .user, content: "hello")],
        tools: nil,
        toolChoice: nil,
        responseFormat: .text,
        generationParameters: GenerationParameters(temperature: 0.2),
        modelTier: .fast
    )
    _ = try await stream.collect()

    #expect(llm.generationCaptureHistory.count == 1)
    #expect(llm.generationCaptureHistory.last?.messages.first?.content == "hello")
    #expect(llm.generationCaptureHistory.last?.modelTier == .fast)
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
- Memory, LLM, and persistence states use mutex-protected snapshots or atomic
  read/modify/write operations. `BatchFailingMessageStore` increments its count and decides
  threshold admission together, and composite request-origin callbacks are snapshotted under lock
  then awaited after unlocking.
- `TestWorkspace` creates a unique directory and removes it best-effort on deinitialization. Retain
  the `TestWorkspace` object—not only its `root` URL—for the entire time the directory is needed.
- `TestRuntime.threads`, `agents`, and `workspaces` exercise the same facade capability values
  used by consumers; concrete coordinators remain internal to the runtime.

## Package Layout

Core modules:

- **PositronicKit** — the runtime layer: turn engine, orchestration stages, tool routing, thread and workspace management, and provider-neutral LLM orchestration.
- **PKPrompt** — the prompt layer: a SwiftUI-style `@PromptBuilder` DSL, structured compression, cache-aware assembly, and prompt journaling for stable-prefix workflows.
- **PKContracts** — the contract layer: API models, tool protocols, provider contracts, structured-output types, and diagnostic errors.
Provider targets ship separately so you opt in only to the integrations you want:

- **PKOpenAIProvider**, **PKOpenRouterProvider**, **PKOllamaProvider**, **PKAnthropicProvider**, **PKFoundationModelsProvider** — concrete adapters plus convenience registration APIs. `PKAnthropicProvider` speaks the Anthropic Messages API natively (event-based SSE, `input_schema` tools, top-level `system` param); structured output uses the forced synthetic-tool path since the API has no `response_format`.

Supporting targets:

- **PKObservable** — opt-in `@Observable` wrappers for UI-facing consumers; `ThreadController` mirrors `ThreadHandle` streaming state for SwiftUI clients.
- **PositronicKitExamples** — runnable examples that double as living documentation.
- **PKTestSupport** — shared mocks, fixtures, and test helpers for downstream test targets.

All declared products are cataloged in [docs/catalog.json](docs/catalog.json). The generated
[documentation navigation](docs/NAVIGATION.md) records the owning guide and compiled consumer gate
for each product.

## Verification

On macOS, build and test with standard SwiftPM commands (`swift build`, `swift test`,
`swift run PositronicKitExamples`). Linux verification always runs through Podman:

```bash
make verify            # Default build, docs, linkage audit, and tests (macOS)
make agent-verify      # Canonical full Linux gate in Podman
make agent-test FILTER='MessageContentTests' # Focused Linux test in Podman
make verify-products   # Build every supported product on the current host
make verify-documentation # Check catalog, generated navigation, links, anchors, pins, and vocabulary
```

`make agent-verify` needs Podman on the host. The pinned image supplies Swift, Rust,
the C/C++ toolchain, and native dependencies. If an agent sandbox blocks Podman,
rerun the same command with escalated container-runtime permissions; do not fall back
to host Swift.

Embeddings and vector retrieval are intentionally outside the current package surface and remain a future direction.

## Linux Development

PositronicKit uses one reproducible Linux development path: the pinned Podman image.

### Podman

The included Dev Container provides Swift 6.3.3, Rust stable, and all native prerequisites on Ubuntu 24.04:

```bash
make linux-image   # Build the development image (swift:6.3.3-noble + Rust + native deps)
make linux-build   # Compile in the container (bind-mounts your checkout)
make agent-verify  # Run the complete product, example, support, and test gate
make agent-test FILTER='MessageContentTests' # Run one focused test selection
```

The shared runner verifies Podman access, builds the pinned image, applies the required
rootless identity and native-linker environment, serializes shared build state, and logs
the gate under `.build/agent-logs/`. The checkout is bind-mounted at `/workspace`, so host
edits are visible immediately and reusable artifacts stay under the gitignored `.build/`
directory. See [`docs/Development.md`](docs/Development.md) for focused-test and concurrency
details.

## Companion App

[`Yakamoz`](https://github.com/phynics/Yakamoz) is the native macOS showcase app for PositronicKit. It drives the runtime from a SwiftUI chat client and exposes the prompt pipeline, sent provider payloads, prompt journal, response metadata, tool traces, and local workspace state through an inspector drawer.
