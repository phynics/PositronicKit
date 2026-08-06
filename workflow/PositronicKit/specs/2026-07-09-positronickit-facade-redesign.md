# PositronicKit Facade Redesign — Design

**Date:** 2026-07-09
**Status:** Draft (brainstormed, pending spec review)
**Scope:** PositronicKit public entry point (`PositronicKit.swift`) and provider-target extensions.

## Motivation

The current `PositronicKit` facade (`struct PositronicKit: Sendable`, `Sources/PositronicKit/PositronicKit.swift`) works but has three shortcomings, in priority order:

1. **Architecturally awkward (primary).** It is a value type copied on every `addPlugin`/`reconfigured`, and it carries a shared `TimelinePromptHistoryRegistry` with a documented footgun: callers who reconstruct facades manually must thread *the same* registry instance through every rebuild or per-timeline prompt-diff and inspection-turn-index state silently resets (see the ~30-line doc comment at `PositronicKit.swift:58-70` and `:121-124`).
2. **Disclosure is only about construction, not usage.** Progressive disclosure today lives in the initializers (`PositronicKit(openAIKey:)` → 16-parameter full init). There is no progressive story for *what you do with it* — one-shot completion vs. stateful conversation vs. full agent loop.
3. **No named levels of operation.** Consumers cannot opt into distinct, named integration tiers.

Non-goal: hiding machinery from power users. Concept-leakage reduction was explicitly deprioritized — power users may see timelines, tool routers, etc. The goal is a cleaner spine, not a smaller surface.

## Design

### 1. Ownership & type shape

`PositronicKit` becomes a **long-lived, immutable configuration owner + factory**:

```swift
public final class PositronicKit: Sendable { ... }
```

- **Reference type, not a value type.** Constructed once and held for the app lifetime. Eliminates the copy-divergence class of bugs entirely.
- **Not an actor.** It holds immutable configuration plus already-actor-isolated collaborators (`TimelineManager` is already an actor; `ToolRouter` is already an actor; stores are actors). Because the mutable state is all behind those actors, the kit itself needs no isolation and stays `Sendable`.
- **Synchronous vending.** `let convo = kit.newConversation()` — no `await` just to obtain a handle. All real concurrency lives one layer down in the vended actors.
- **Single shared registry.** The kit owns exactly one `TimelinePromptHistoryRegistry` and hands it to every handle/manager it vends. No consumer can construct a handle wired to the wrong registry, so the footgun disappears by construction.

Intended consumer pattern: wrap `kit` in an application-owned `Service` class; obtain managers/controllers from it and pass those into the relevant app subsystems.

### 2. The operation ladder (progressive disclosure)

Access model is **hybrid**: flat vending from `kit` is the primary API; each vended handle exposes a *minimal* escape hatch so a consumer can go one level deeper without returning to `kit`, but without full tier-to-tier coupling.

| Tier | Entry point | Returns | Persistence / tools |
|------|-------------|---------|---------------------|
| 1 One-shot | `kit.complete(_:)` / `kit.stream(_:)` | `String` / `AsyncThrowingStream<...>` | none — prompt in, text out |
| 2 Conversation | `kit.newConversation()` / `kit.conversation(timelineId:)` | `Conversation` (pure cursor) | timeline-backed, multi-turn, optional tools |
| 3 Timeline | `kit.timelineManager` | `TimelineManager` | direct timeline/workspace control |
| 4 Agent | `kit.agenticRuntime(...)` | `AgenticRuntime` (wraps `AgentInstanceManager`) | full tool/agent loop against timeline + workspace + agent instance |
| 5 Raw | `kit.toolRouter`, `kit.llmService`, prompt DSL | primitives | assemble a bespoke pipeline |

Notes:
- **Tier 4 name:** `AgenticRuntime`. It is a wrapper/rename over the existing `AgentInstanceManager` — no new orchestration logic, just the tier-4 public face.
- **Tier 2 `send`** returns `AsyncThrowingStream<ChatEvent, Error>` per send (matches today's `run`/`ChatEvent` model). The handle stays a stateless cursor; SwiftUI consumers iterate the stream and update their own view models.

### 3. Handles are pure cursors

`Conversation` (and the other vended handles) are lightweight `Sendable` values that are pure cursors over the kit-owned stores + registry — they hold **no** live in-memory turn state.

- `Conversation` is `Identifiable` with `var id: UUID { timelineId }`.
- `timelineId` is minted **once** at creation (`kit.newConversation()`) or supplied by the caller, and persisted in the stores.
- `kit.conversation(timelineId:)` returns a **fresh** handle on each call; two handles for the same id point at the same underlying timeline state.
- **SwiftUI identity** keys off the stable domain id (`timelineId`), not object identity, so re-fetching a fresh handle causes no view churn. No caching in the kit → no eviction/lifecycle problem.
- **Escape hatches:** `Conversation.timelineId`, and scoped access to the underlying `TimelineManager` for tier-3 escalation.

Coordination that would otherwise need a shared live handle (in-flight turn, cancellation, subscriber fan-out) lives in the kit-owned actors (`TimelineManager` / a per-id turn actor), **not** in the handle. This is what makes fresh-per-call safe.

**Explicitly rejected:** caching one live handle per id in the kit. It would force the kit to own a mutable `[id: Handle]` map (an actor or lock, breaking the immutable-`Sendable` model) and introduce an eviction/lifecycle problem (the same `RegistryEvictionPolicy` complexity that already burdens the prompt-history registry).

### 4. Construction

Layered initializers, collapsed to ~3 forms in core:

```swift
// Generic convenience — provider-agnostic.
public convenience init(llmService: any LLMServiceProtocol = UnconfiguredLLMService())

// One full form behind grouped config structs, replacing today's 16-parameter init.
public init(configuration: PositronicKit.Configuration)
```

- The grouped `Configuration` bundles `provider` / `persistence` / `runtime` sub-configs (superseding the current flat 16-parameter initializer).
- **Provider-specific conveniences move out of core** into their provider targets, as extensions on `PositronicKit`:

  ```swift
  // in PKOpenAIProvider
  extension PositronicKit { public convenience init(openAIKey: String, ...) }
  ```

  Likewise `PositronicKit(anthropicKey:)` in `PKAnthropicProvider`, `PositronicKit(ollamaModel:)` in `PKOllamaProvider`, `PositronicKit(foundationModelsTools:)` in `PKFoundationModelsProvider`. `import PKOpenAIProvider` is what lights up `PositronicKit(openAIKey:)`. This aligns with the standing architecture rule that concrete provider adapters stay out of the core runtime target.

### 5. Downstream sync

The facade is public PositronicKit API. Per the workspace downstream-sync checklist, changes here must be grepped through **all three** consumers — Monad, Shuttle, Yakamoz — for the changed construction/entry symbols before landing, and exercised via the local-path override until a compatible PositronicKit tag is cut.

## Deferred to follow-up tickets

- **`@Observable` `Conversation` wrapper.** An `@Observable` convenience (binding `messages`/`isStreaming`/`streamingText` directly for SwiftUI) is *not* in core. It lives downstream in the consumer (Yakamoz) or an opt-in `PKObservable`-style module, keeping core SwiftUI-agnostic. Separate ticket.
- **Migration/back-compat plan** for existing `PositronicKit(...)` call sites across the three consumers (the current struct init surface → new class + grouped `Configuration`).
- **Exact `Configuration` sub-struct field layout** (`provider`/`persistence`/`runtime`) — to be specified in the implementation plan.

## Open questions

- Does tier 1 (`complete`/`stream`) need timeline-free execution support in the runtime, or is it a thin wrapper that spins an ephemeral, non-persisted timeline under the hood?
- Should `agenticRuntime(...)` vend fresh per call like conversations, or is agent-instance identity different enough to warrant a distinct rule?
