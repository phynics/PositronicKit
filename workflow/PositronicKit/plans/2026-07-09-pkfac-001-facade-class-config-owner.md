# PKFAC-001: `PositronicKit` struct → `final class` config owner — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert `PositronicKit` from a value-type `struct` (copied on every `addPlugin`/`reconfigured`) into a long-lived, immutable `final class` configuration owner, eliminating the shared-registry copy-divergence footgun by construction.

**Architecture:** `PositronicKit` keeps its exact current public surface (`timelineManager`, `toolRouter`, `run(_:)`) but becomes a reference type. It owns exactly one `TimelinePromptHistoryRegistry`, built internally — the `promptHistoryRegistry:` init parameter is removed entirely, so no caller can construct an instance wired to the wrong registry. `reconfigured(...)` and `addPlugin(_:)` change from copy-and-return to either in-place mutation or construction of a genuinely new instance (see Task 3 for the exact call — `reconfigured` inherently needs new stored `llmService`/`chatEngine`, so it stays "build a new instance," but the *registry* is no longer a parameter you can get wrong).

**Tech Stack:** Swift 6, Swift Testing (`@Suite`, `@Test`, `#expect`) and XCTest (match existing file conventions), `swift test` via `PositronicKit/` package.

**Ticket:** [`PKFAC-001`](../tickets/PKFAC-001-facade-class-config-owner.md). Design: [`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md) §1.

---

## Pre-flight: confirmed blast radius (2026-07-09)

`grep -rl "PositronicKit(" --include="*.swift" .` (excluding `.build/`) inside `PositronicKit/` shows **no downstream consumer files** (Monad/Shuttle/Yakamoz aren't in this repo checkout) — every call site is inside the `PositronicKit` package itself:

- `Sources/PositronicKit/PositronicKit.swift` — the type itself.
- `Sources/PositronicKitExamples/PositronicKitUsageExamples.swift` — example factories.
- `Sources/PKFoundationModelsProvider/PKFoundationModelsProvider.swift` — provider convenience init (delegates to `init(llmService:)`, unaffected by struct→class as long as `self.init(...)` still resolves — but `struct` convenience delegation (`self.init(...)`) becomes `convenience init` delegation for a class; this file's own `public extension PositronicKit { init(foundationModelsTools:) { ... self.init(llmService: ...) } }`-style pattern needs the same `convenience` treatment. Check this in Task 1.
- 13 files under `Tests/PositronicKitTests/` and `Tests/PKTestSupport/TestRuntime.swift`.
- Two call sites use `.addPlugin(`: `Tests/PositronicKitTests/Stories/Runtime/PublicRuntimeStoriesTests.swift:222`, `Tests/PositronicKitTests/Stories/Extensions/ExtensionStoriesTests.swift:31`.
- One call site uses `.reconfigured(`: `Tests/PositronicKitTests/TurnInspectingTests.swift:268`.
- One call site uses `.addStage(`: `Tests/PositronicKitTests/Stories/Runtime/PublicRuntimeStoriesTests.swift:252` (`customStage`). This exercises the exact same "must return an independent instance, not alias `self`" path as `addPlugin` — Task 3 Step 3's fix applies to it identically. Treat it as required regression coverage, not optional.

No `PKFAC-008` downstream-migration work is triggered by this ticket (it's delayed anyway) — this plan is scoped entirely to the `PositronicKit` package.

## File Structure

- **Modify:** `Sources/PositronicKit/PositronicKit.swift` — `struct` → `final class`; drop `promptHistoryRegistry:` params; convert `init` to `convenience init` where it delegates; change `addStage`/`addPlugin` from copy-return to mutation; decide `reconfigured`'s new shape (Task 3).
- **Modify:** `Sources/PositronicKit/PositronicKit+Configuration.swift` — the two grouped `init`s become `convenience init`; drop `promptHistoryRegistry:` threading (registry is now internal-only).
- **Modify:** `Sources/PKFoundationModelsProvider/PKFoundationModelsProvider.swift` (and check `PKOpenAIProvider`/`PKAnthropicProvider`/`PKOllamaProvider` similarly) — their `public extension PositronicKit { init(...) }` become `convenience init(...)`.
- **Modify (call-site updates only, no new files):** the three test files identified above that call `.addPlugin(` / `.reconfigured(`.
- **No new files.** This is a type-shape change, not new functionality.

---

### Task 1: Confirm exact scope of `convenience init` conversions

**Files:**
- Read: `Sources/PKOpenAIProvider/PKOpenAIProvider.swift`
- Read: `Sources/PKAnthropicProvider/PKAnthropicProvider.swift`
- Read: `Sources/PKOllamaProvider/PKOllamaProvider.swift`
- Read: `Sources/PKFoundationModelsProvider/PKFoundationModelsProvider.swift`

- [ ] **Step 1: Grep every `public extension PositronicKit { init(` across the four provider targets**

Run: `grep -rn "extension PositronicKit" Sources/PKOpenAIProvider Sources/PKAnthropicProvider Sources/PKOllamaProvider Sources/PKFoundationModelsProvider`

Expected: four hits, one per provider target (confirmed in prior investigation — `PKOpenAIProvider.swift:35`, `PKAnthropicProvider.swift:22`, `PKOllamaProvider.swift:19`, `PKFoundationModelsProvider.swift:22`).

- [ ] **Step 2: Read each and note whether its `init` delegates via `self.init(...)`**

All four currently do (e.g. `PKOpenAIProvider.swift:41`: `self.init(llmService: llm, generationParameters: generationParameters)`). For a `struct`, a delegating `init` in an extension is just `init`. For a `final class`, **any initializer that delegates to another initializer on the same type via `self.init(...)` must be declared `convenience init`** — Swift requires this; non-convenience (designated) inits on a class must initialize stored properties directly, not delegate. Record this — it's the reason Task 4 exists.

- [ ] **Step 3: No commit for this task — it's read-only scoping.** Proceed to Task 2.

---

### Task 2: Convert `PositronicKit` from `struct` to `final class`, remove `promptHistoryRegistry:` parameter

**Files:**
- Modify: `Sources/PositronicKit/PositronicKit.swift:28` (type declaration), `:70` (stored property), `:81-92` (simple init), `:129-207` (designated init), `:145` (param to remove)
- Test: `Tests/PositronicKitTests/DependencySafetyTests.swift` (or wherever facade construction is smoke-tested — confirm exact file when running tests in Step 2)

- [ ] **Step 1: Write/confirm a regression test asserting registry identity is internal**

Since `promptHistoryRegistry:` is being *removed* as a public parameter, there's no "pass a custom registry" test to keep — instead add a test proving two facades built from the same stores share conversation-diff state correctly *without* the caller doing anything special. If `DependencySafetyTests.swift` or similar already covers facade construction, extend it; otherwise add to a suitable existing suite (do not create a new test file for one assertion — check `Tests/PositronicKitTests/` for the closest existing home first).

```swift
// Illustrative — adapt to the actual test file's existing helpers/harness pattern.
@Test
func facadeOwnsItsOwnPromptHistoryRegistryInternally() {
    // Construction no longer accepts a promptHistoryRegistry: parameter at all —
    // this test exists to lock in that the type still compiles and behaves
    // correctly without one now that it's an internal implementation detail.
    let kit = PositronicKit(llmService: UnconfiguredLLMService())
    #expect(kit.timelineManager != nil) // placeholder assertion; replace with
    // whatever the existing dependency-safety suite already checks post-construction.
}
```

- [ ] **Step 2: Run the test suite to confirm current (pre-change) baseline is green**

Run: `swift test --filter PositronicKitTests`
Expected: PASS (baseline, before any change — confirms starting point).

- [ ] **Step 3: Change `struct PositronicKit: Sendable` → `final class PositronicKit: Sendable`**

At `PositronicKit.swift:28`. Because `TimelineManager`/`ToolRouter`/stores are all actors, and the class holds only `let`s (plus the two `private var`s noted below), it remains safely `Sendable` — confirm the compiler agrees once `var chatTurnPlugins`/`var chatEngine` are addressed in Task 3, since a class with mutable stored `var` properties is **not** automatically `Sendable` the way a `struct` is; those two need to become either `let` (if mutation moves to producing a genuinely new instance) or be wrapped so the class stays `Sendable`. Resolve this in lockstep with Task 3 — don't declare `final class ... : Sendable` and expect it to compile with `private var chatTurnPlugins` still present.

- [ ] **Step 4: Remove `promptHistoryRegistry:` from both the private stored property and every init parameter**

- `PositronicKit.swift:70`: keep `private let promptHistoryRegistry: TimelinePromptHistoryRegistry` as a stored property, but change its initialization from `= promptHistoryRegistry` (the removed param) to `= TimelinePromptHistoryRegistry()` constructed inline in the designated init.
- `PositronicKit.swift:145`: delete the `promptHistoryRegistry: TimelinePromptHistoryRegistry = TimelinePromptHistoryRegistry()` parameter from the designated init entirely.
- `PositronicKit.swift:160`: change `self.promptHistoryRegistry = promptHistoryRegistry` to `self.promptHistoryRegistry = TimelinePromptHistoryRegistry()`.
- `PositronicKit.swift:186`: `promptHistoryRegistry: promptHistoryRegistry` (passed to `TimelineManager`) becomes `promptHistoryRegistry: self.promptHistoryRegistry`.
- `PositronicKit.swift:204`: same — becomes `promptHistoryRegistry: self.promptHistoryRegistry`.
- `PositronicKit+Configuration.swift:61-63` (doc comment referencing "why hosts that rebuild PositronicKit per send must pass the same instance every time") — delete this now-obsolete paragraph (the footgun this whole ticket exists to kill). **Only the first grouped init** (`PersistenceConfiguration`-taking, lines 68-96) has a `promptHistoryRegistry:` parameter — at `:75` (param declaration) and `:92` (forwarding in the `self.init(...)` call). Remove both. **The second grouped init** (`RuntimeConfiguration`-taking, lines 143-169) has **no** `promptHistoryRegistry:` parameter at all today — do not go looking for a second occurrence to remove; there is none.

- [ ] **Step 5: Mark the in-type simple init (`:81-92`) as `convenience`**

`PositronicKit.swift:81` (`public init(llmService:turnInspector:generationParameters:)`) delegates via `self.init(llmService:persistence:turnInspector:generationParameters:)` — a call into the *grouped* `PersistenceConfiguration` init in `PositronicKit+Configuration.swift`, which Task 4 below is converting to `convenience init`. Any Swift class initializer that delegates via `self.init(...)` must itself be `convenience`, so this one needs the keyword too, independent of and in addition to the four provider-target conversions in Task 4. Change `public init(` → `public convenience init(` at line 81. Without this step, `swift build --target PositronicKit` fails at this exact call site with "designated initializer for a class cannot delegate (with 'self.init')" — this is a real compile failure, not covered by Task 4's scope (which only touches the four provider targets), so it must land here in Task 2.

- [ ] **Step 6: Update `PositronicKit.swift:58-70`'s large doc comment**

Replace the ~13-line comment explaining the registry-threading footgun with a short note: "Owned internally; every conversation vended by this instance shares it automatically. Construct a new `PositronicKit` for a genuinely separate cross-send history." This is a direct requirement of the ticket ("footgun doc comments deleted").

- [ ] **Step 7: Attempt compile — expect failures in `reconfigured`/`addPlugin`/`addStage`, which Task 3 fixes next**

Run: `swift build --target PositronicKit`
Expected: FAIL — `struct`-specific copy semantics (`var copy = self`) no longer compile on a `final class` without `var` properties changing meaning. This is expected; do not fix yet, that's Task 3. Do not commit mid-failure.

---

### Task 3: Fix `reconfigured` / `addPlugin` / `addStage` for class semantics

**Files:**
- Modify: `Sources/PositronicKit/PositronicKit.swift:43` (`chatTurnPlugins` var), `:56` (`chatEngine` var), `:215-239` (`reconfigured`), `:243-254` (`addStage`), `:256-278` (`addPlugin`)

The old `struct` pattern (`var copy = self; copy.chatTurnPlugins.append(...); return copy`) relied on value semantics: mutating `copy` never touched `self`. On a `final class`, `var copy = self` aliases the *same* object — mutating `copy.chatTurnPlugins` would mutate `self.chatTurnPlugins` too, silently breaking the "returns a new instance" contract every caller of `addPlugin`/`addStage` currently relies on (see the two call sites in `PublicRuntimeStoriesTests.swift:222` and `ExtensionStoriesTests.swift:31`, both of which bind the result to a *new* `let chat = baseChat.addPlugin(plugin)` and keep using `baseChat` separately — if that pattern still needs to hold, mutation-in-place is wrong).

- [ ] **Step 1: Decide and record: does `addPlugin` mutate in place, or construct a new instance?**

Check both call sites' full context first:

Run: `sed -n '1,40p' Tests/PositronicKitTests/Stories/Extensions/ExtensionStoriesTests.swift` and `sed -n '200,240p' Tests/PositronicKitTests/Stories/Runtime/PublicRuntimeStoriesTests.swift`

If `baseChat` is used again after `.addPlugin(plugin)` is called and is expected to **not** have the plugin (i.e. the test's whole point is proving non-mutation / a fresh instance), keep `addPlugin` returning a **new** `PositronicKit` instance built via the designated `init` (same as today's *intent*, just now genuinely constructing a second class instance instead of struct-copying). If `baseChat` is never used again post-call, mutation-in-place (`mutating`-equivalent: since class methods aren't `mutating`, just directly assign `self.chatTurnPlugins.append(plugin)` and return `self`) is simpler and matches the "long-lived, held instance" ownership model PKFAC-001 establishes. **Default recommendation: keep constructing a new instance** (matches existing call-site expectations exactly, zero test rewrites needed, and matches the ticket's requirement to "audit all call sites first... and record the chosen replacement").

- [ ] **Step 2: Add a private designated init that accepts an existing registry + additional pipeline stages**

This is the concrete fix for the contradiction flagged in plan review: the *public* designated init (Task 2) always builds a fresh `TimelinePromptHistoryRegistry()` internally, which is correct for callers constructing an independent facade — but wrong for `addPlugin`/`addStage`/`reconfigured`, which must produce a new instance that shares `self`'s existing registry (otherwise cross-send prompt-diff/inspection-index state silently resets, reintroducing the exact bug this ticket exists to kill). Add a second, `private` designated init alongside the public one at `PositronicKit.swift:129-207`, identical in every parameter except two additions:

```swift
private init(
    llmService: any LLMStreamClient & LLMConfigStore & LLMUtilityClient,
    messageStore: (any MessageStoreProtocol)? = nil,
    agentInstanceStore: (any AgentInstanceStoreProtocol)? = nil,
    requestOriginStore: (any RequestOriginStoreProtocol)? = nil,
    timelinePersistence: (any TimelinePersistenceProtocol)? = nil,
    workspacePersistence: (any WorkspacePersistenceProtocol)? = nil,
    memoryStore: (any MemoryStoreProtocol)? = nil,
    toolPersistence: (any ToolPersistenceProtocol)? = nil,
    embeddingService: (any EmbeddingServiceProtocol)? = nil,
    workspaceRoot: URL? = nil,
    workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
    sectionProviders: [any PromptSectionProviding] = [],
    runtimeToolPolicy: TimelineManager.RuntimeToolPolicy = .default,
    chatTurnPlugins: [any ChatTurnPlugin] = [],
    turnInspector: (any TurnInspecting)? = nil,
    generationParameters: GenerationParameters? = nil,
    toolApprovalGate: any ToolApprovalGate = DenyAllToolApprovalGate(),
    sharedRegistry: TimelinePromptHistoryRegistry,           // NEW — reuse instead of building fresh
    additionalStages: [any PipelineStage<ChatTurnContext, ChatEvent>] = []  // NEW — carry forward addStage state
) {
    self.llmService = llmService
    // ... identical body to the public designated init, except:
    self.promptHistoryRegistry = sharedRegistry              // was: TimelinePromptHistoryRegistry()
    // ... build resolvedTimelineManager / toolRouter exactly as before, passing self.promptHistoryRegistry ...
    var engine = ChatEngine(
        dependencies: .init(
            timelineManager: resolvedTimelineManager,
            agentInstanceStore: self.agentInstanceStore,
            requestOriginStore: self.requestOriginStore,
            messageStore: self.messageStore,
            llmService: self.llmService,
            toolRouter: toolRouter,
            chatTurnPlugins: self.chatTurnPlugins,
            turnInspector: self.turnInspector,
            promptHistoryRegistry: self.promptHistoryRegistry
        )
    )
    engine.additionalStages = additionalStages
    chatEngine = engine
}
```

The public designated init from Task 2 becomes a thin wrapper that delegates here with `sharedRegistry: TimelinePromptHistoryRegistry()` and `additionalStages: []` — this avoids duplicating the full body. Since `PositronicKit` is now a class, delegating a designated init to another designated init on the same type isn't allowed directly; instead keep the *private* init as the single source of truth for the full body (as sketched above) and make the *public* one a `convenience init` that calls `self.init(..., sharedRegistry: TimelinePromptHistoryRegistry(), additionalStages: [])`.

- [ ] **Step 3: Implement `addPlugin`/`addStage`/`reconfigured` using the private shared-registry init**

```swift
public func addPlugin(_ plugin: any ChatTurnPlugin) -> PositronicKit {
    PositronicKit(
        llmService: llmService,
        messageStore: messageStore,
        agentInstanceStore: agentInstanceStore,
        requestOriginStore: requestOriginStore,
        timelinePersistence: timelinePersistence,
        workspacePersistence: workspacePersistence,
        memoryStore: memoryStore,
        toolPersistence: toolPersistence,
        embeddingService: embeddingService,
        workspaceRoot: workspaceRoot,
        workspaceCreator: workspaceCreator,
        sectionProviders: sectionProviders,
        runtimeToolPolicy: runtimeToolPolicy,
        chatTurnPlugins: chatTurnPlugins + [plugin],
        turnInspector: turnInspector,
        generationParameters: defaultGenerationParameters,
        toolApprovalGate: toolApprovalGate,
        sharedRegistry: promptHistoryRegistry,
        additionalStages: chatEngine.additionalStages
    )
}

func addStage(_ stage: any PipelineStage<ChatTurnContext, ChatEvent>) -> PositronicKit {
    PositronicKit(
        /* ...identical passthrough of every stored property as addPlugin above... */
        chatTurnPlugins: chatTurnPlugins,
        turnInspector: turnInspector,
        generationParameters: defaultGenerationParameters,
        toolApprovalGate: toolApprovalGate,
        sharedRegistry: promptHistoryRegistry,
        additionalStages: chatEngine.additionalStages + [stage]
    )
}
```

`reconfigured(llmService:generationParameters:)` (`PositronicKit.swift:215-239`) gets the same treatment: swap its existing `PositronicKit(...)` call to the private init, adding `sharedRegistry: promptHistoryRegistry, additionalStages: chatEngine.additionalStages` to the argument list so it also preserves cross-send state — this is the ticket's core bug fix, and today's `reconfigured` already threads `promptHistoryRegistry: promptHistoryRegistry` explicitly (line 235), so this step is a straightforward rename of that argument to the new private-init parameter name, not new behavior.

- [ ] **Step 4: Change `chatTurnPlugins` and `chatEngine` from `private var` to `private let`**

Since every builder method now constructs a genuinely new instance (never mutates `self`), `chatTurnPlugins` and `chatEngine` no longer need to be `var` — they're set once in whichever designated init runs and never touched again. Update `PositronicKit.swift:43,56` to `private let`. This is required for the class to satisfy `Sendable` (a class conforming to `Sendable` needs all stored state either immutable or independently synchronized; ChatEngine itself is a plain `struct`, not an actor, so a `var chatEngine` on the class would make cross-thread mutation unsafe and the compiler will reject the `Sendable` conformance).

- [ ] **Step 5: Build**

Run: `swift build --target PositronicKit`
Expected: PASS.

- [ ] **Step 6: Run the full test suite**

Run: `swift test --filter PositronicKitTests`
Expected: PASS, including all four call sites identified in pre-flight (`PublicRuntimeStoriesTests.swift:222` and `:252`, `ExtensionStoriesTests.swift:31`, `TurnInspectingTests.swift:268`) with **no code changes required in those test files**, since the chosen semantics preserve "returns a new, independent instance."

- [ ] **Step 7: Commit**

```bash
git add Sources/PositronicKit/PositronicKit.swift Sources/PositronicKit/PositronicKit+Configuration.swift
git commit -m "refactor(PKFAC-001): PositronicKit struct -> final class, single owned prompt-history registry"
```

---

### Task 4: Convert provider convenience inits to `convenience init`

**Files:**
- Modify: `Sources/PKOpenAIProvider/PKOpenAIProvider.swift`
- Modify: `Sources/PKAnthropicProvider/PKAnthropicProvider.swift`
- Modify: `Sources/PKOllamaProvider/PKOllamaProvider.swift`
- Modify: `Sources/PKFoundationModelsProvider/PKFoundationModelsProvider.swift`

- [ ] **Step 1: Add `convenience` to each provider's `init` that delegates via `self.init(...)`**

Example (`PKOpenAIProvider.swift:36-42`):

```swift
public extension PositronicKit {
    convenience init(
        openAIKey: String,
        model: String = "gpt-4o",
        generationParameters: GenerationParameters? = nil
    ) {
        PKOpenAIProvider.register()
        let config = LLMConfiguration(modelName: model, apiKey: openAIKey, provider: .openAI)
        let llm = LLMService(configuration: config)
        self.init(llmService: llm, generationParameters: generationParameters)
    }
}
```

Repeat for `PKAnthropicProvider`, `PKOllamaProvider`, `PKFoundationModelsProvider` — same pattern, same fix (add `convenience`).

- [ ] **Step 2: Build each provider target**

Run: `swift build --target PKOpenAIProvider --target PKAnthropicProvider --target PKOllamaProvider --target PKFoundationModelsProvider`
Expected: PASS. Without `convenience`, the compiler error is explicit ("designated initializer for a class cannot delegate (with 'self.init')") — if any target still errors, it means Task 1's scope check missed a delegating init; fix and retry.

- [ ] **Step 3: Run each provider's test target if one exists**

Run: `swift test --filter ProviderInitializationTests` (per `Tests/PositronicKitTests/Services/LLM/Providers/ProviderInitializationTests.swift` identified in pre-flight)
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/PKOpenAIProvider Sources/PKAnthropicProvider Sources/PKOllamaProvider Sources/PKFoundationModelsProvider
git commit -m "fix(PKFAC-001): provider convenience inits declared 'convenience' for class facade"
```

---

### Task 5: Update `PositronicKitExamples` and doc comments

**Files:**
- Modify: `Sources/PositronicKitExamples/PositronicKitUsageExamples.swift`
- Modify: `Sources/PositronicKit/PositronicKit.swift:7-27` (type doc comment)

- [ ] **Step 1: Build the examples target — it should compile unchanged**

Run: `swift build --target PositronicKitExamples`
Expected: PASS with no source changes needed (the examples call the same public inits/methods; only the underlying type shape changed). If it fails, the failure output names the exact line to fix — apply the minimal fix, no speculative changes.

- [ ] **Step 2: Update `PositronicKit`'s type doc comment to describe it as a long-lived reference type**

At `PositronicKit.swift:7-27`, add one sentence noting: "Construct once and hold for the app's lifetime — `PositronicKit` is a reference type (`final class`); building a new instance starts a new, independent cross-send history." This is separate from the full ladder documentation (that's `PKFAC-007`'s job) — just correct the now-stale "value type" implication in the existing comment.

- [ ] **Step 3: Commit**

```bash
git add Sources/PositronicKit/PositronicKit.swift Sources/PositronicKitExamples/PositronicKitUsageExamples.swift
git commit -m "docs(PKFAC-001): note PositronicKit is now a reference type in its type doc"
```

---

### Task 6: Full package verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full PositronicKit test suite**

Run: `cd PositronicKit && swift test`
Expected: PASS, same test count as the pre-change baseline captured in Task 2 Step 2 (no tests should be silently skipped — cross-check the executed count per the workspace's known `PKFastEmbed zero-tests` pitfall memory: a green run with 0 tests executed is not success).

- [ ] **Step 2: Run the docs/build gate**

Run: `make verify`
Expected: PASS.

- [ ] **Step 3: Run the products build gate**

Run: `make verify-products`
Expected: PASS — confirms every product (including the four provider targets touched in Task 4) builds standalone.

- [ ] **Step 4: Update the ticket**

Edit `workflow/PositronicKit/tickets/PKFAC-001-facade-class-config-owner.md`: flip `Triage:` to `wontfix`/mark Done-equivalent per this repo's lifecycle convention, add a `Status:` line with the commit hash(es) and a one-line resolution note ("struct → final class, single internally-owned registry, `addPlugin`/`addStage`/`reconfigured` construct genuinely new instances via a private shared-registry path").

- [ ] **Step 5: Final commit**

```bash
git add workflow/PositronicKit/tickets/PKFAC-001-facade-class-config-owner.md
git commit -m "tickets(pk): close PKFAC-001 (PositronicKit struct -> final class)"
```

---

## Notes for the next plan (PKFAC-002)

PKFAC-002 depends on this ticket landing first specifically because it rewrites the same designated-init signatures this plan just stabilized (collapsing the flat 16-parameter init + the two existing grouped inits into one `Configuration`-taking init). Do not start PKFAC-002 until Task 6 here is fully green — rebasing a struct→class conversion underneath an in-flight init-signature rewrite is exactly the kind of double-work this plan's sequencing is designed to avoid.
