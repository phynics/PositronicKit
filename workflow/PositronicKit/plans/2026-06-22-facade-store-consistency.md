# Facade Store Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `PositronicKit`'s facade the single construction site for `TimelineManager`/`ToolRouter`, so persistence stores can never silently diverge between the facade's `persistence:` block and a separately-built `TimelineManager`.

**Architecture:** Remove the `timelineManager:`/`toolRouter:` override parameters from both the raw and grouped `PositronicKit` initializers. Replace them with the non-store knobs `TimelineManager` actually needs beyond its stores — `workspaceCreator`, `sectionProviders`, `runtimeToolPolicy` — added to `RuntimeConfiguration` and the raw initializer. The facade always derives `TimelineManager.Stores` from `PersistenceConfiguration` and always builds `ToolRouter` from that one `TimelineManager`. Expose `timelineManager`/`toolRouter` as public read-only properties so callers that need the constructed instances (for pre-seeding timelines, or for routing) pull them back out of the facade instead of building their own copy and feeding it in.

**Tech Stack:** Swift 6.1, Swift Package Manager, Swift Testing (`@Suite`/`@Test`/`#expect`), `swift test`

---

## Global Constraints

- Breaking changes are acceptable; there is no deprecation/back-compat shim required for `timelineManager:`/`toolRouter:` removal.
- Every call site that currently builds a `TimelineManager`/`ToolRouter` and hands it to the facade must be migrated in this same change: `PositronicKit` itself, `PKTestSupport.TestRuntime`, `PositronicKitExamples`, 4 files under `Tests/PositronicKitTests`, and `Monad/Sources/MonadServer/MonadServerFactory.swift`.
- `Shuttle/Sources/ShuttleServer/Agents/ShuttleShardAgentRunner.swift` uses the flat per-store initializer and never passes `timelineManager:`/`toolRouter:` — it needs no code change, only a build check.
- `swift build && swift test` must pass in `PositronicKit` and in `Monad` before this is done.

## Background (why this exists)

The facade currently lets a caller pass `persistence:` (a set of stores) **and separately** a pre-built `TimelineManager`/`ToolRouter` that may wrap *different* store instances. `TimelineManager` snapshots its stores once at construction (`Sources/PositronicKit/Services/Timeline/TimelineManager.swift:83-110`), so once built it can never be told "actually, use this messageStore instead."

This is not hypothetical: `Monad/Sources/MonadServer/MonadServerFactory.swift:256-262` builds `TimelineManager.Stores` **without** `memoryStore`, so it silently defaults to `InMemoryMemoryStore()` (`TimelineManager.swift:51`), while `MonadServerFactory.swift:74-87` hands the facade's `persistence:` block the real GRDB-backed `repositories.memoryStore`. Two different memory stores are live in the same server today. The reason callers build their own `TimelineManager` at all is that `RuntimeConfiguration` has no slot for `workspaceCreator` (Monad needs `WorkspaceFactory(connectionManager:)` for WebSocket-backed workspaces) — so the override parameter is the only way to plug it in, and that's exactly the seam where stores can drift.

---

### Task 1: Add Non-Store Runtime Knobs and Remove the Override Parameters

**Files:**
- Modify: `Sources/PositronicKit/PositronicKit.swift`

**Interfaces:**
- Consumes: `TimelineManager.Stores`, `TimelineManager.RuntimeToolPolicy`, `WorkspaceCreating`, `PromptSectionProviding`
- Produces: `PositronicKit.RuntimeConfiguration` without `timelineManager`/`toolRouter` fields; raw initializer without `timelineManager:`/`toolRouter:` parameters; facade always builds its own `TimelineManager`/`ToolRouter`

- [ ] **Step 1: Rewrite the raw initializer (`PositronicKit.swift:86-143`) to drop the overrides and always build `TimelineManager`/`ToolRouter` from the stores**

Replace:

```swift
    public init(
        llmService: any LLMServiceProtocol,
        messageStore: (any MessageStoreProtocol)? = nil,
        timelineManager: TimelineManager? = nil,
        toolRouter: ToolRouter? = nil,
        agentInstanceStore: (any AgentInstanceStoreProtocol)? = nil,
        requestOriginStore: (any RequestOriginStoreProtocol)? = nil,
        timelinePersistence: (any TimelinePersistenceProtocol)? = nil,
        workspacePersistence: (any WorkspacePersistenceProtocol)? = nil,
        memoryStore: (any MemoryStoreProtocol)? = nil,
        toolPersistence: (any ToolPersistenceProtocol)? = nil,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        workspaceRoot: URL? = nil,
        chatTurnPlugins: [any ChatTurnPlugin] = [],
        generationParameters: GenerationParameters? = nil
    ) {
        self.llmService = llmService
        self.messageStore = messageStore ?? InMemoryMessageStore()
        self.agentInstanceStore = agentInstanceStore ?? InMemoryAgentInstanceStore()
        self.requestOriginStore = requestOriginStore ?? InMemoryRequestOriginStore()
        self.timelinePersistence = timelinePersistence ?? InMemoryTimelinePersistence()
        self.workspacePersistence = workspacePersistence ?? InMemoryWorkspacePersistence()
        self.memoryStore = memoryStore ?? InMemoryMemoryStore()
        self.toolPersistence = toolPersistence ?? InMemoryToolPersistence()
        self.embeddingService = embeddingService ?? NoOpEmbeddingService()
        self.chatTurnPlugins = chatTurnPlugins
        defaultGenerationParameters = generationParameters

        let resolvedWorkspaceRoot = workspaceRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-workspaces", isDirectory: true)
        let resolvedTimelineManager = timelineManager ?? TimelineManager(
            stores: .init(
                timelineStore: self.timelinePersistence,
                messageStore: self.messageStore,
                workspaceStore: self.workspacePersistence,
                toolPersistence: self.toolPersistence,
                memoryStore: self.memoryStore
            ),
            workspaceRoot: resolvedWorkspaceRoot,
            embeddingService: self.embeddingService
        )
        self.timelineManager = resolvedTimelineManager
        self.toolRouter = toolRouter ?? ToolRouter(
            timelineManager: resolvedTimelineManager,
            messageStore: self.messageStore
        )
        chatEngine = ChatEngine(
            dependencies: .init(
                timelineManager: resolvedTimelineManager,
                agentInstanceStore: self.agentInstanceStore,
                requestOriginStore: self.requestOriginStore,
                messageStore: self.messageStore,
                llmService: self.llmService,
                toolRouter: self.toolRouter,
                chatTurnPlugins: self.chatTurnPlugins
            )
        )
    }
```

With:

```swift
    public init(
        llmService: any LLMServiceProtocol,
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
        generationParameters: GenerationParameters? = nil
    ) {
        self.llmService = llmService
        self.messageStore = messageStore ?? InMemoryMessageStore()
        self.agentInstanceStore = agentInstanceStore ?? InMemoryAgentInstanceStore()
        self.requestOriginStore = requestOriginStore ?? InMemoryRequestOriginStore()
        self.timelinePersistence = timelinePersistence ?? InMemoryTimelinePersistence()
        self.workspacePersistence = workspacePersistence ?? InMemoryWorkspacePersistence()
        self.memoryStore = memoryStore ?? InMemoryMemoryStore()
        self.toolPersistence = toolPersistence ?? InMemoryToolPersistence()
        self.embeddingService = embeddingService ?? NoOpEmbeddingService()
        self.chatTurnPlugins = chatTurnPlugins
        defaultGenerationParameters = generationParameters

        let resolvedWorkspaceRoot = workspaceRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-workspaces", isDirectory: true)
        // The facade is the only place a TimelineManager gets built: every store it wraps
        // comes from the same `persistence` surface the rest of the facade uses, so there is
        // no seam where ChatEngine and TimelineManager can end up looking at different stores.
        let resolvedTimelineManager = TimelineManager(
            stores: .init(
                timelineStore: self.timelinePersistence,
                messageStore: self.messageStore,
                workspaceStore: self.workspacePersistence,
                toolPersistence: self.toolPersistence,
                memoryStore: self.memoryStore
            ),
            workspaceRoot: resolvedWorkspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: self.embeddingService
        )
        self.timelineManager = resolvedTimelineManager
        self.toolRouter = ToolRouter(
            timelineManager: resolvedTimelineManager,
            messageStore: self.messageStore
        )
        chatEngine = ChatEngine(
            dependencies: .init(
                timelineManager: resolvedTimelineManager,
                agentInstanceStore: self.agentInstanceStore,
                requestOriginStore: self.requestOriginStore,
                messageStore: self.messageStore,
                llmService: self.llmService,
                toolRouter: self.toolRouter,
                chatTurnPlugins: self.chatTurnPlugins
            )
        )
    }
```

Also update the doc comment above this initializer (currently says "Auto-constructed if nil" for `timelineManager`/`toolRouter`) to read:

```swift
    /// Initializes with all services required by the chat subsystem.
    ///
    /// The facade always constructs its own `TimelineManager` and `ToolRouter` from the stores
    /// passed here, so there is exactly one place that turns persistence stores into runtime
    /// objects — callers cannot end up with a `TimelineManager` that silently wraps different
    /// store instances than the rest of the facade. Use `workspaceCreator`, `sectionProviders`,
    /// and `runtimeToolPolicy` to configure the `TimelineManager` that gets built; read the
    /// constructed instances back via the `timelineManager` / `toolRouter` properties if your
    /// host needs them for its own routing.
    ///
    /// - Parameters:
    ///   - llmService: The LLM service to use for generation.
    ///   - messageStore: The store for persisting chat messages. Defaults to in-memory if nil.
    ///   - agentInstanceStore: Persistence for agent instance data. Defaults to in-memory if nil.
    ///   - requestOriginStore: Persistence for request-origin identity data. Defaults to in-memory if nil.
    ///   - timelinePersistence: Persistence for timeline records. Defaults to in-memory if nil.
    ///   - workspacePersistence: Persistence for workspace records. Defaults to in-memory if nil.
    ///   - memoryStore: Persistence for memory records. Defaults to in-memory if nil.
    ///   - toolPersistence: Persistence for tool references. Defaults to in-memory if nil.
    ///   - embeddingService: Embedding provider for context/memory search. Defaults to no-op if nil.
    ///   - workspaceRoot: Root directory for the constructed `TimelineManager`. Defaults to temp directory.
    ///   - workspaceCreator: Creates concrete workspaces for the constructed `TimelineManager`. Defaults to `NullWorkspaceCreator`.
    ///   - sectionProviders: Prompt sections injected into every turn. Defaults to none.
    ///   - runtimeToolPolicy: Which built-in tool families the `TimelineManager` installs. Defaults to `.default`.
    ///   - chatTurnPlugins: Post-turn plugins (e.g. autonomous reactions).
    ///   - generationParameters: Optional default parameters for generation.
```

- [ ] **Step 2: Update `RuntimeConfiguration` (`PositronicKit.swift:296-317`) to carry the same knobs instead of pre-built instances**

Replace:

```swift
    struct RuntimeConfiguration: Sendable {
        public let timelineManager: TimelineManager?
        public let toolRouter: ToolRouter?
        public let workspaceRoot: URL?
        public let chatTurnPlugins: [any ChatTurnPlugin]

        public init(
            timelineManager: TimelineManager? = nil,
            toolRouter: ToolRouter? = nil,
            workspaceRoot: URL? = nil,
            chatTurnPlugins: [any ChatTurnPlugin] = []
        ) {
            self.timelineManager = timelineManager
            self.toolRouter = toolRouter
            self.workspaceRoot = workspaceRoot
            self.chatTurnPlugins = chatTurnPlugins
        }

        public static func `default`() -> RuntimeConfiguration {
            RuntimeConfiguration()
        }
    }
```

With:

```swift
    /// Groups the non-store knobs `TimelineManager` needs, so the facade can build it from
    /// `PersistenceConfiguration`'s stores while still letting hosts configure workspace
    /// creation, injected prompt sections, and which built-in tool families get installed.
    struct RuntimeConfiguration: Sendable {
        public let workspaceCreator: any WorkspaceCreating
        public let sectionProviders: [any PromptSectionProviding]
        public let runtimeToolPolicy: TimelineManager.RuntimeToolPolicy
        public let workspaceRoot: URL?
        public let chatTurnPlugins: [any ChatTurnPlugin]

        public init(
            workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
            sectionProviders: [any PromptSectionProviding] = [],
            runtimeToolPolicy: TimelineManager.RuntimeToolPolicy = .default,
            workspaceRoot: URL? = nil,
            chatTurnPlugins: [any ChatTurnPlugin] = []
        ) {
            self.workspaceCreator = workspaceCreator
            self.sectionProviders = sectionProviders
            self.runtimeToolPolicy = runtimeToolPolicy
            self.workspaceRoot = workspaceRoot
            self.chatTurnPlugins = chatTurnPlugins
        }

        public static func `default`() -> RuntimeConfiguration {
            RuntimeConfiguration()
        }
    }
```

- [ ] **Step 3: Update the two grouped initializers (`PositronicKit.swift:330-382`) to forward the new fields**

Replace the `persistence:` + `runtime:` initializer body:

```swift
    init(
        llmService: any LLMServiceProtocol,
        persistence: PersistenceConfiguration,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        runtime: RuntimeConfiguration,
        generationParameters: GenerationParameters? = nil
    ) {
        self.init(
            llmService: llmService,
            messageStore: persistence.messageStore,
            timelineManager: runtime.timelineManager,
            toolRouter: runtime.toolRouter,
            agentInstanceStore: persistence.agentInstanceStore,
            requestOriginStore: persistence.requestOriginStore,
            timelinePersistence: persistence.timelinePersistence,
            workspacePersistence: persistence.workspacePersistence,
            memoryStore: persistence.memoryStore,
            toolPersistence: persistence.toolPersistence,
            embeddingService: embeddingService,
            workspaceRoot: runtime.workspaceRoot,
            chatTurnPlugins: runtime.chatTurnPlugins,
            generationParameters: generationParameters
        )
    }
```

With:

```swift
    init(
        llmService: any LLMServiceProtocol,
        persistence: PersistenceConfiguration,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        runtime: RuntimeConfiguration,
        generationParameters: GenerationParameters? = nil
    ) {
        self.init(
            llmService: llmService,
            messageStore: persistence.messageStore,
            agentInstanceStore: persistence.agentInstanceStore,
            requestOriginStore: persistence.requestOriginStore,
            timelinePersistence: persistence.timelinePersistence,
            workspacePersistence: persistence.workspacePersistence,
            memoryStore: persistence.memoryStore,
            toolPersistence: persistence.toolPersistence,
            embeddingService: embeddingService,
            workspaceRoot: runtime.workspaceRoot,
            workspaceCreator: runtime.workspaceCreator,
            sectionProviders: runtime.sectionProviders,
            runtimeToolPolicy: runtime.runtimeToolPolicy,
            chatTurnPlugins: runtime.chatTurnPlugins,
            generationParameters: generationParameters
        )
    }
```

The single-argument `persistence:` grouped initializer (`PositronicKit.swift:330-356`, the one that doesn't take `runtime:`) calls the raw initializer directly with `timelineManager: timelineManager, toolRouter: toolRouter` from its own `timelineManager:`/`toolRouter:` parameters — remove those two parameters from that initializer's signature too, since it has no `RuntimeConfiguration` to source replacement knobs from; its callers needing custom `workspaceCreator` etc. should use the `runtime:`-taking overload instead. Its preceding doc comment also lists those two removed parameters:

```swift
    /// Creates a PositronicKit with grouped persistence configuration.
    ///
    /// - Parameters:
    ///   - llmService: The LLM service to use for generation (required).
    ///   - persistence: All persistence stores grouped together.
    ///   - embeddingService: Embedding provider. Defaults to no-op.
    ///   - timelineManager: Timeline orchestrator. Auto-constructed if nil.
    ///   - toolRouter: Tool routing. Auto-constructed if nil.
    ///   - workspaceRoot: Root directory for workspaces. Defaults to temp directory.
    ///   - chatTurnPlugins: Post-turn plugins. Defaults to none.
    ///   - generationParameters: Optional default parameters for generation.
```

Delete the `timelineManager:`/`toolRouter:` lines from that comment block (they no longer exist as parameters). Its body becomes:

```swift
    init(
        llmService: any LLMServiceProtocol,
        persistence: PersistenceConfiguration,
        embeddingService: (any EmbeddingServiceProtocol)? = nil,
        workspaceRoot: URL? = nil,
        chatTurnPlugins: [any ChatTurnPlugin] = [],
        generationParameters: GenerationParameters? = nil
    ) {
        self.init(
            llmService: llmService,
            messageStore: persistence.messageStore,
            agentInstanceStore: persistence.agentInstanceStore,
            requestOriginStore: persistence.requestOriginStore,
            timelinePersistence: persistence.timelinePersistence,
            workspacePersistence: persistence.workspacePersistence,
            memoryStore: persistence.memoryStore,
            toolPersistence: persistence.toolPersistence,
            embeddingService: embeddingService,
            workspaceRoot: workspaceRoot,
            chatTurnPlugins: chatTurnPlugins,
            generationParameters: generationParameters
        )
    }
```

- [ ] **Step 4: Build to confirm the facade compiles**

Run: `swift build`
Expected: FAIL — downstream call sites (`PositronicKitExamples`, `PKTestSupport`) still reference the removed `timelineManager:`/`toolRouter:` parameters. That's expected; they're fixed in later tasks. Confirm the *error* is specifically about those removed parameters (missing argument labels), not something else.

### Task 2: Expose `timelineManager` / `toolRouter` Publicly and Lock In the Invariant

**Files:**
- Modify: `Sources/PositronicKit/PositronicKit.swift:27-38`
- Modify: `Tests/PositronicKitTests/DependencySafetyTests.swift`

- [ ] **Step 1: Make the two properties public**

In the `// MARK: - Direct ChatEngine dependencies` block, change:

```swift
    let llmService: any LLMServiceProtocol
    private let messageStore: any MessageStoreProtocol
    // Non-private so DependencySafetyTests can assert the facade reuses the injected timeline manager.
    let timelineManager: TimelineManager
    private let toolRouter: ToolRouter
```

To:

```swift
    let llmService: any LLMServiceProtocol
    private let messageStore: any MessageStoreProtocol
    /// The `TimelineManager` this facade constructed from its persistence stores. Read this
    /// instead of building a second `TimelineManager` when a host needs the instance for its
    /// own routing — building a second one is exactly the divergence this facade prevents.
    public let timelineManager: TimelineManager
    /// The `ToolRouter` this facade constructed alongside `timelineManager`.
    public let toolRouter: ToolRouter
```

- [ ] **Step 2: Add a regression test that the facade-built `TimelineManager` shares the persistence `memoryStore`**

This is the exact bug class found in `Monad/Sources/MonadServer/MonadServerFactory.swift` (a `TimelineManager` built with `memoryStore` omitted defaults to `InMemoryMemoryStore()`, diverging from the GRDB-backed store passed to the facade). Add to `Tests/PositronicKitTests/DependencySafetyTests.swift`, inside the existing `@Suite struct DependencySafetyTests`:

```swift
    @Test("Facade-built TimelineManager reuses the persistence memoryStore — no silent divergence")
    func facadeTimelineManagerSharesMemoryStore() async throws {
        let mockPersistence = MockPersistenceService()
        let chat = PositronicKit(
            llmService: MockLLMService(),
            persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )
        )

        let usedMemoryStore = await chat.timelineManager.memoryStore as? MockPersistenceService
        #expect(usedMemoryStore === mockPersistence)
    }
```

- [ ] **Step 3: Run the dependency safety tests**

Run: `swift test --filter DependencySafetyTests`
Expected: Still fails to build at this point (Task 1's removed parameters aren't migrated everywhere yet) — that's fine, this step is about having the test in place; it goes green once Tasks 3–6 finish migrating the package's other call sites.

### Task 3: Migrate `PKTestSupport.TestRuntime`

**Files:**
- Modify: `Tests/PKTestSupport/TestRuntime.swift`

- [ ] **Step 1: Build the facade first, then derive `timelineManager`/`toolRouter` from it**

`TestRuntime` currently builds its own `TimelineManager`/`ToolRouter` and threads them into `buildCore()`. Flip that: build the `PositronicKit` once in `init`, store it, and expose `timelineManager`/`toolRouter` as forwarding properties so existing call sites like `runtime.timelineManager.createTimeline(...)` keep working unchanged.

Replace the whole file body from `public struct TestRuntime: Sendable {` through the closing of `init` (lines 16-87) with:

```swift
    public struct TestRuntime: Sendable {
        public let persistence: MockPersistenceService
        public let llm: MockLLMService
        public let embedding: MockEmbeddingService

        private let core: PositronicKit

        public var timelineManager: TimelineManager { core.timelineManager }
        public var toolRouter: ToolRouter { core.toolRouter }

        public let agentWorkspaceService: AgentWorkspaceService
        public let agentInstanceManager: AgentInstanceManager
        public let workspaceManager: WorkspaceManager

        /// Creates a fully-wired runtime. Every collaborator is built from the supplied
        /// `persistence`, so the whole graph — including the facade's own `TimelineManager` —
        /// shares one backing store.
        ///
        /// - Parameters:
        ///   - workspaceRoot: Unique root directory for this runtime's workspaces.
        ///   - persistence: Backing store shared by every collaborator. Defaults to a fresh mock.
        ///   - llm: Mock LLM service. Defaults to a fresh mock.
        ///   - embedding: Mock embedding service. Defaults to a fresh mock.
        ///   - workspaceCreator: Workspace factory for the facade's `TimelineManager`. Defaults to `MockWorkspaceCreator`.
        public init(
            workspaceRoot: URL,
            persistence: MockPersistenceService = MockPersistenceService(),
            llm: MockLLMService = MockLLMService(),
            embedding: MockEmbeddingService = MockEmbeddingService(),
            workspaceCreator: any WorkspaceCreating = MockWorkspaceCreator()
        ) {
            self.persistence = persistence
            self.llm = llm
            self.embedding = embedding

            core = PositronicKit(
                llmService: llm,
                persistence: .init(
                    messageStore: persistence,
                    timelinePersistence: persistence,
                    workspacePersistence: persistence,
                    memoryStore: persistence,
                    toolPersistence: persistence,
                    agentInstanceStore: persistence,
                    requestOriginStore: persistence
                ),
                embeddingService: embedding,
                runtime: .init(
                    workspaceCreator: workspaceCreator,
                    workspaceRoot: workspaceRoot
                )
            )

            let agentWorkspaceService = AgentWorkspaceService(
                workspaceRoot: workspaceRoot,
                workspacePersistence: persistence
            )
            self.agentWorkspaceService = agentWorkspaceService
            agentInstanceManager = AgentInstanceManager(
                repository: agentWorkspaceService,
                stores: .init(
                    instanceStore: persistence,
                    timelineStore: persistence,
                    messageStore: persistence,
                    workspaceStore: persistence
                )
            )
            workspaceManager = WorkspaceManager(
                repository: agentWorkspaceService,
                workspaceCreator: workspaceCreator
            )
        }

        /// Returns the `PositronicKit` facade this runtime is wired to.
        public func buildCore() -> PositronicKit {
            core
        }
    }
```

- [ ] **Step 2: Build PKTestSupport**

Run: `swift build --target PKTestSupport`
Expected: PASS

### Task 4: Migrate `PositronicKitExamples`

**Files:**
- Modify: `Sources/PositronicKitExamples/PositronicKitUsageExamples.swift:21-97`

- [ ] **Step 1: Simplify `makeConfiguredRuntime` and `makeProductionRuntime`**

These two functions currently build a `TimelineManager`/`ToolRouter` by hand from a `TimelineManager.Stores` that only includes 4 of the 5 stores `PersistenceConfiguration` carries (no `memoryStore`) — that's the exact bug pattern, now also unreachable: the parameters they used to pass (`runtime: .init(timelineManager:, toolRouter:)`) no longer exist. Replace both functions:

```swift
    public static func makeConfiguredRuntime() -> PositronicKit {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-examples", isDirectory: true)

        return PositronicKit(
            llmService: UnconfiguredLLMService(),
            persistence: .inMemory(),
            embeddingService: NoOpEmbeddingService(),
            runtime: .init(workspaceRoot: workspaceRoot)
        )
    }

    public static func makeConfiguredOpenAIRuntime(apiKey: String = "sk-example") -> PositronicKit {
        PKOpenAIProvider.register()
        return PositronicKit(
            llmService: LLMService(configuration: .init(
                apiKey: apiKey,
                provider: .openAI
            ))
        )
    }

    public static func makeProductionRuntime() -> PositronicKit {
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("positronickit-examples-production", isDirectory: true)

        return PositronicKit(
            llmService: UnconfiguredLLMService(),
            persistence: .init(
                messageStore: InMemoryMessageStore(),
                timelinePersistence: InMemoryTimelinePersistence(),
                workspacePersistence: InMemoryWorkspacePersistence(),
                memoryStore: InMemoryMemoryStore(),
                toolPersistence: InMemoryToolPersistence(),
                agentInstanceStore: InMemoryAgentInstanceStore(),
                requestOriginStore: InMemoryRequestOriginStore()
            ),
            embeddingService: NoOpEmbeddingService(),
            runtime: .init(workspaceRoot: workspaceRoot)
        )
    }
```

(`makeConfiguredOpenAIRuntime` is unchanged in content — included above only to show it stays between the other two, since it sits between them in the file today.)

- [ ] **Step 2: Build and run the examples executable**

Run: `swift build --target PositronicKitExamples && swift run PositronicKitExamples`
Expected: PASS, prints the example output as before.

### Task 5: Update Public Docs

**Files:**
- Modify: `Sources/PositronicKit/README.md:60-79`
- Modify: `Sources/PositronicKit/docs/Usage.md:60-110`

- [ ] **Step 1: Fix the `README.md` "Getting Started" snippet**

The grouped-init example currently shows `runtime: .init(timelineManager: myTimelineManager)`. Replace that line with a knob a host would actually plug in:

```swift
let chat = PositronicKit(
    llmService: myLLM,
    persistence: .init(
        messageStore: myMessageStore,
        timelinePersistence: myTimelinePersistence,
        workspacePersistence: myWorkspacePersistence,
        memoryStore: myMemoryStore,
        toolPersistence: myToolPersistence,
        agentInstanceStore: myAgentInstanceStore,
        requestOriginStore: myRequestOriginStore
    ),
    embeddingService: myEmbeddingService,
    runtime: .init(
        workspaceCreator: myWorkspaceCreator
    )
)
```

- [ ] **Step 2: Fix the two `docs/Usage.md` snippets the same way**

Both the "Full Initialization (Production)" snippet and the "Running a Chat Stream" snippet currently show `runtime: .init(timelineManager: myTimelineManager, toolRouter: myToolRouter)`. Replace both occurrences with `runtime: .init(workspaceCreator: myWorkspaceCreator)`, and add a short note above the first occurrence:

```markdown
The facade always builds its own `TimelineManager` and `ToolRouter` from the stores in
`persistence:` — there is no way to hand it a separately-built `TimelineManager`, so the
stores it uses for timeline/workspace state can never drift from the stores it uses for
chat persistence. If your host needs the constructed `TimelineManager` or `ToolRouter`
afterward (for its own routes, say), read them back via `chat.timelineManager` / `chat.toolRouter`.
```

- [ ] **Step 3: Spot-check rendering**

No automated check for markdown; visually confirm both files no longer reference `timelineManager:`/`toolRouter:` as initializer arguments.

### Task 6: Migrate the Affected `PositronicKitTests` Files

**Files:**
- Modify: `Tests/PositronicKitTests/Stories/Extensions/ExtensionStoriesTests.swift:119-173`
- Modify: `Tests/PositronicKitTests/Stories/Examples/IntroductoryStoriesTests.swift:48-122`
- Modify: `Tests/PositronicKitTests/Stories/Runtime/PublicRuntimeStoriesTests.swift:245-401`
- Modify: `Tests/PositronicKitTests/Stories/Setup/RuntimeSetupStoriesTests.swift:119-149`

All four follow the same shape: build a `TimelineManager` by hand (so they can call `createTimeline`/`attachWorkspace` on it *before* the facade exists), then hand it to the facade via the now-removed override. Fix: build the facade first with the right `runtime:` knobs, pull `chat.timelineManager` back out, then do the pre-seeding.

- [ ] **Step 1: Fix `ExtensionStoriesTests.makeAcceptanceRuntime` (lines 119-173)**

Replace the helper body:

```swift
    private func makeAcceptanceRuntime(
        workspaceCreator: any WorkspaceCreating = MockWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        includeDefaultToolWorkspace: Bool = true
    ) async throws -> (PositronicKit, MockLLMService, MockPersistenceService, UUID, TestWorkspace, TimelineManager) {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let chat = PositronicKit(
            llmService: mockLLM,
            persistence: .init(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            ),
            runtime: .init(
                workspaceCreator: workspaceCreator,
                sectionProviders: sectionProviders,
                workspaceRoot: workspace.root
            )
        )
        let timelineManager = chat.timelineManager

        let timeline = try await timelineManager.createTimeline(title: "Extension Acceptance")

        if includeDefaultToolWorkspace {
            let workspaceId = UUID()
            let workspaceRef = WorkspaceReference(
                id: workspaceId,
                uri: WorkspaceURI(parsing: "pk://local")!,
                location: .runtimeTimeline,
                originId: nil,
                rootPath: workspace.root.path
            )
            try await mockPersistence.saveWorkspace(workspaceRef)
            try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("acceptance_tool"))
            try await timelineManager.attachWorkspace(workspaceId, to: timeline.id)
        }

        return (chat, mockLLM, mockPersistence, timeline.id, workspace, timelineManager)
    }
```

- [ ] **Step 2: Fix `IntroductoryStoriesTests.runtimeToolRoundTripExample` (lines 48-122)**

Replace the `timelineManager`/`runtime` construction block:

```swift
        let workspace = TestWorkspace()
        let mockLLM = MockLLMService()
        let persistence = MockPersistenceService()
```

```swift
        mockLLM.mockClient.nextToolCalls = [[
            MockToolCall(id: "call_1", name: "intro_greet", arguments: #"{"name":"Taylor"}"#),
        ]]
        mockLLM.mockClient.nextResponses = ["", "I greeted Taylor successfully."]

        let runtime = PositronicKit(
            llmService: mockLLM,
            persistence: PositronicKit.PersistenceConfiguration(
                messageStore: persistence,
                timelinePersistence: persistence,
                workspacePersistence: persistence,
                memoryStore: persistence,
                toolPersistence: persistence,
                agentInstanceStore: persistence,
                requestOriginStore: persistence
            ),
            runtime: .init(
                workspaceCreator: MockWorkspaceCreator(),
                workspaceRoot: workspace.root
            )
        )
        let timelineManager = runtime.timelineManager

        let timeline = try await timelineManager.createTimeline(title: "Intro Example")
```

removing the standalone `let timelineManager = TimelineManager(...)` block (the old lines 52-61) and the old `runtime: .init(timelineManager:, toolRouter:)` block, and removing the now-duplicate `let timeline = try await timelineManager.createTimeline(...)` that used to appear later in the function. Everything below `let timeline = ...` (the tool/workspace attach and the `runtime.run(...)` call) stays as-is, just keep using `runtime` and `timelineManager` from the rewritten block above.

- [ ] **Step 3: Fix `PublicRuntimeStoriesTests.runUsesTimelineContextManagerByDefault` (lines 245-294)**

Replace:

```swift
    @Test
    func runUsesTimelineContextManagerByDefault() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: mockPersistence,
                messageStore: mockPersistence,
                workspaceStore: mockPersistence,
                toolPersistence: mockPersistence
            ),
            workspaceRoot: workspace.root,
            workspaceCreator: MockWorkspaceCreator()
        )
        let timeline = try await timelineManager.createTimeline(title: "Context Enabled")

        mockLLM.mockClient.nextResponse = "Hello with context"

        let chat = PositronicKit(
            llmService: mockLLM,
            messageStore: mockPersistence,
            timelineManager: timelineManager,
            agentInstanceStore: mockPersistence,
            requestOriginStore: mockPersistence,
            timelinePersistence: mockPersistence,
            workspacePersistence: mockPersistence,
            memoryStore: mockPersistence,
            toolPersistence: mockPersistence
        )
```

With:

```swift
    @Test
    func runUsesTimelineContextManagerByDefault() async throws {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let chat = PositronicKit(
            llmService: mockLLM,
            messageStore: mockPersistence,
            agentInstanceStore: mockPersistence,
            requestOriginStore: mockPersistence,
            timelinePersistence: mockPersistence,
            workspacePersistence: mockPersistence,
            memoryStore: mockPersistence,
            toolPersistence: mockPersistence,
            workspaceRoot: workspace.root,
            workspaceCreator: MockWorkspaceCreator()
        )
        let timeline = try await chat.timelineManager.createTimeline(title: "Context Enabled")

        mockLLM.mockClient.nextResponse = "Hello with context"
```

- [ ] **Step 4: Fix `PublicRuntimeStoriesTests.makeAcceptanceRuntime` (lines 316-401)**

This helper builds `timelineManager` once, then branches into three different facade-construction shapes (flat init, grouped init without `runtime:`, grouped init with `runtime:`) to exercise each public initializer shape. Replace the whole function:

```swift
    private func makeAcceptanceRuntime(
        useGroupedPersistence: Bool = false,
        useGroupedRuntime: Bool = false
    ) async throws -> (PositronicKit, MockLLMService, MockPersistenceService, UUID, TestWorkspace) {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let chat: PositronicKit
        if useGroupedPersistence {
            let persistence = PositronicKit.PersistenceConfiguration(
                messageStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence
            )

            if useGroupedRuntime {
                chat = PositronicKit(
                    llmService: mockLLM,
                    persistence: persistence,
                    runtime: .init(
                        workspaceCreator: MockWorkspaceCreator(),
                        workspaceRoot: workspace.root
                    )
                )
            } else {
                chat = PositronicKit(
                    llmService: mockLLM,
                    persistence: persistence,
                    workspaceRoot: workspace.root
                )
            }
        } else {
            chat = PositronicKit(
                llmService: mockLLM,
                messageStore: mockPersistence,
                agentInstanceStore: mockPersistence,
                requestOriginStore: mockPersistence,
                timelinePersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                memoryStore: mockPersistence,
                toolPersistence: mockPersistence,
                workspaceRoot: workspace.root,
                workspaceCreator: MockWorkspaceCreator()
            )
        }

        let timelineManager = chat.timelineManager
        let timeline = try await timelineManager.createTimeline(title: "Acceptance")

        let workspaceId = UUID()
        let workspaceRef = WorkspaceReference(
            id: workspaceId,
            uri: WorkspaceURI(parsing: "pk://local")!,
            location: .runtimeTimeline,
            originId: nil,
            rootPath: workspace.root.path
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await timelineManager.attachWorkspace(workspaceId, to: timeline.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("mock_tool"))

        return (chat, mockLLM, mockPersistence, timeline.id, workspace)
    }
```

Note: the `useGroupedPersistence: false, useGroupedRuntime: false` branch (flat initializer) and the `useGroupedPersistence: true, useGroupedRuntime: false` branch (grouped persistence, no `runtime:`) now exercise genuinely different code paths than before — both still valid since the single-argument `persistence:` grouped initializer keeps its own `workspaceRoot:`/`chatTurnPlugins:` parameters (Task 1, Step 3) but lost `timelineManager:`/`toolRouter:`. Confirm both still compile.

- [ ] **Step 5: Fix `RuntimeSetupStoriesTests.unconfiguredFacadeRunFails` (lines 119-149)**

Replace:

```swift
    @Test("Unconfigured facade run fails before attempting execution")
    func unconfiguredFacadeRunFails() async throws {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()
        let timelineManager = TimelineManager(
            workspaceRoot: workspace.root,
            workspaceCreator: MockWorkspaceCreator()
        )

        let timeline = try await timelineManager.createTimeline(title: "Unconfigured")

        let persistence = PositronicKit.PersistenceConfiguration(
            messageStore: mockPersistence,
            timelinePersistence: mockPersistence,
            workspacePersistence: mockPersistence,
            memoryStore: mockPersistence,
            toolPersistence: mockPersistence,
            agentInstanceStore: mockPersistence,
            requestOriginStore: mockPersistence
        )

        let chat = PositronicKit(
            llmService: UnconfiguredLLMService(),
            persistence: persistence,
            runtime: .init(timelineManager: timelineManager)
        )

        await #expect(throws: ChatEngineError.self) {
            _ = try await chat.run(timelineId: timeline.id, message: "hello")
        }
    }
```

With:

```swift
    @Test("Unconfigured facade run fails before attempting execution")
    func unconfiguredFacadeRunFails() async throws {
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let persistence = PositronicKit.PersistenceConfiguration(
            messageStore: mockPersistence,
            timelinePersistence: mockPersistence,
            workspacePersistence: mockPersistence,
            memoryStore: mockPersistence,
            toolPersistence: mockPersistence,
            agentInstanceStore: mockPersistence,
            requestOriginStore: mockPersistence
        )

        let chat = PositronicKit(
            llmService: UnconfiguredLLMService(),
            persistence: persistence,
            runtime: .init(
                workspaceCreator: MockWorkspaceCreator(),
                workspaceRoot: workspace.root
            )
        )
        let timeline = try await chat.timelineManager.createTimeline(title: "Unconfigured")

        await #expect(throws: ChatEngineError.self) {
            _ = try await chat.run(timelineId: timeline.id, message: "hello")
        }
    }
```

- [ ] **Step 6: Run the full PositronicKit test suite**

Run: `swift test`
Expected: PASS — every story under `Tests/PositronicKitTests`, including the new `DependencySafetyTests.facadeTimelineManagerSharesMemoryStore` from Task 2, and `PKLocalEmbeddingsTests`/`PKPromptTests`/`PKSharedTests`.

- [ ] **Step 7: Commit**

```bash
git add Sources/PositronicKit/PositronicKit.swift \
        Sources/PositronicKit/README.md \
        Sources/PositronicKit/docs/Usage.md \
        Sources/PositronicKitExamples/PositronicKitUsageExamples.swift \
        Tests/PKTestSupport/TestRuntime.swift \
        Tests/PositronicKitTests/DependencySafetyTests.swift \
        Tests/PositronicKitTests/Stories/Extensions/ExtensionStoriesTests.swift \
        Tests/PositronicKitTests/Stories/Examples/IntroductoryStoriesTests.swift \
        Tests/PositronicKitTests/Stories/Runtime/PublicRuntimeStoriesTests.swift \
        Tests/PositronicKitTests/Stories/Setup/RuntimeSetupStoriesTests.swift
git commit -m "Make PositronicKit the sole TimelineManager/ToolRouter construction site"
```

### Task 7: Fix the Live Divergence in Monad

**Files:**
- Modify: `Monad/Sources/MonadServer/MonadServerFactory.swift`

- [ ] **Step 1: Remove `timelineManager`/`toolRouter` from `ManagerSet` and stop building them in `initializeManagers`**

Change the `ManagerSet` struct (around line 53):

```swift
    private struct ManagerSet {
        let timelineManager: TimelineManager
        let toolRouter: ToolRouter
        let agentInstanceManager: any AgentInstanceManagerProtocol
        let workspaceManager: any WorkspaceManagerProtocol
    }
```

To:

```swift
    private struct ManagerSet {
        let agentInstanceManager: any AgentInstanceManagerProtocol
        let workspaceManager: any WorkspaceManagerProtocol
    }
```

Change `initializeManagers` (around lines 247-288) — this is where the live bug lives, since `timelineManager` was built without `memoryStore`:

```swift
    private static func initializeManagers(
        repositories: RepositorySet,
        workspaceRoot: URL,
        connectionManager: WebSocketConnectionManager
    ) -> ManagerSet {
        let agentWorkspaceService = AgentWorkspaceService(
            workspaceRoot: workspaceRoot,
            workspacePersistence: repositories.workspacePersistence
        )
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: repositories.timelinePersistence,
                messageStore: repositories.messageStore,
                workspaceStore: repositories.workspacePersistence,
                toolPersistence: repositories.toolPersistence
            ),
            workspaceRoot: workspaceRoot,
            workspaceCreator: WorkspaceFactory(connectionManager: connectionManager)
        )
        let toolRouter = ToolRouter(
            timelineManager: timelineManager,
            messageStore: repositories.messageStore
        )

        return ManagerSet(
            timelineManager: timelineManager,
            toolRouter: toolRouter,
            agentInstanceManager: AgentInstanceManager(
                repository: agentWorkspaceService,
                stores: .init(
                    instanceStore: repositories.agentInstanceStore,
                    timelineStore: repositories.timelinePersistence,
                    messageStore: repositories.messageStore,
                    workspaceStore: repositories.workspacePersistence
                )
            ),
            workspaceManager: WorkspaceManager(
                repository: agentWorkspaceService,
                workspaceCreator: WorkspaceFactory(connectionManager: connectionManager)
            )
        )
    }
```

To:

```swift
    private static func initializeManagers(
        repositories: RepositorySet,
        workspaceRoot: URL,
        connectionManager: WebSocketConnectionManager
    ) -> ManagerSet {
        let agentWorkspaceService = AgentWorkspaceService(
            workspaceRoot: workspaceRoot,
            workspacePersistence: repositories.workspacePersistence
        )

        return ManagerSet(
            agentInstanceManager: AgentInstanceManager(
                repository: agentWorkspaceService,
                stores: .init(
                    instanceStore: repositories.agentInstanceStore,
                    timelineStore: repositories.timelinePersistence,
                    messageStore: repositories.messageStore,
                    workspaceStore: repositories.workspacePersistence
                )
            ),
            workspaceManager: WorkspaceManager(
                repository: agentWorkspaceService,
                workspaceCreator: WorkspaceFactory(connectionManager: connectionManager)
            )
        )
    }
```

- [ ] **Step 2: Build the facade with `workspaceCreator` instead of a hand-built `TimelineManager`/`ToolRouter`**

In `createServerContext` (around lines 74-87), change:

```swift
        let coreChat = PositronicKit(
            llmService: components.services.llmService,
            persistence: .init(
                messageStore: components.repositories.messageStore,
                timelinePersistence: components.repositories.timelinePersistence,
                workspacePersistence: components.repositories.workspacePersistence,
                memoryStore: components.repositories.memoryStore,
                toolPersistence: components.repositories.toolPersistence,
                agentInstanceStore: components.repositories.agentInstanceStore,
                requestOriginStore: components.repositories.requestOriginStore
            ),
            embeddingService: components.services.embeddingService,
            timelineManager: components.managers.timelineManager,
            toolRouter: components.managers.toolRouter
        )
```

To:

```swift
        let coreChat = PositronicKit(
            llmService: components.services.llmService,
            persistence: .init(
                messageStore: components.repositories.messageStore,
                timelinePersistence: components.repositories.timelinePersistence,
                workspacePersistence: components.repositories.workspacePersistence,
                memoryStore: components.repositories.memoryStore,
                toolPersistence: components.repositories.toolPersistence,
                agentInstanceStore: components.repositories.agentInstanceStore,
                requestOriginStore: components.repositories.requestOriginStore
            ),
            embeddingService: components.services.embeddingService,
            runtime: .init(
                workspaceCreator: WorkspaceFactory(connectionManager: components.services.connectionManager)
            )
        )
```

This now resolves the live bug: `coreChat.timelineManager` is built from the exact same `repositories.memoryStore` (GRDB-backed) that the rest of the facade uses — there is no second, in-memory-defaulted memory store anymore.

- [ ] **Step 3: Replace every remaining `components.managers.timelineManager` / `.toolRouter` reference with `coreChat.timelineManager` / `coreChat.toolRouter`**

These occur at the original lines 100, 104, 118, 119 (the route-registration calls that happen after `coreChat` is constructed):

```swift
        registerChatAndTimelineRoutes(
            on: protected,
            connectionManager: components.services.connectionManager,
            chat: coreChat,
            timelineManager: components.managers.timelineManager,
            timelineStore: components.repositories.timelinePersistence,
            workspaceStore: components.repositories.workspacePersistence,
            agentInstanceStore: components.repositories.agentInstanceStore,
            toolRouter: components.managers.toolRouter,
            verbose: verbose
        )
        registerResourceRoutes(
            on: protected,
            dependencies: .init(
                memoryStore: components.repositories.memoryStore,
                messageStore: components.repositories.messageStore,
                timelineStore: components.repositories.timelinePersistence,
                workspaceStore: components.repositories.workspacePersistence,
                toolStore: components.repositories.toolPersistence,
                agentTemplateStore: components.repositories.agentTemplateStore,
                requestOriginStore: components.repositories.requestOriginStore,
                workspaceManager: components.managers.workspaceManager,
                timelineManager: components.managers.timelineManager,
                toolRouter: components.managers.toolRouter,
                databaseManager: components.databaseManager,
                ...
```

becomes:

```swift
        registerChatAndTimelineRoutes(
            on: protected,
            connectionManager: components.services.connectionManager,
            chat: coreChat,
            timelineManager: coreChat.timelineManager,
            timelineStore: components.repositories.timelinePersistence,
            workspaceStore: components.repositories.workspacePersistence,
            agentInstanceStore: components.repositories.agentInstanceStore,
            toolRouter: coreChat.toolRouter,
            verbose: verbose
        )
        registerResourceRoutes(
            on: protected,
            dependencies: .init(
                memoryStore: components.repositories.memoryStore,
                messageStore: components.repositories.messageStore,
                timelineStore: components.repositories.timelinePersistence,
                workspaceStore: components.repositories.workspacePersistence,
                toolStore: components.repositories.toolPersistence,
                agentTemplateStore: components.repositories.agentTemplateStore,
                requestOriginStore: components.repositories.requestOriginStore,
                workspaceManager: components.managers.workspaceManager,
                timelineManager: coreChat.timelineManager,
                toolRouter: coreChat.toolRouter,
                databaseManager: components.databaseManager,
                ...
```

Use `grep -n "components.managers.timelineManager\|components.managers.toolRouter" Monad/Sources/MonadServer/MonadServerFactory.swift` before and after this step to confirm every occurrence is replaced (expect 0 matches after).

- [ ] **Step 4: Build and test Monad**

Run: `cd Monad && swift build`
Expected: PASS

Run: `swift test`
Expected: PASS — pay particular attention to any test exercising memory persistence end-to-end through the server (e.g. memory-related controller tests), since this is the path that was silently broken before this fix.

- [ ] **Step 5: Commit**

```bash
git add Monad/Sources/MonadServer/MonadServerFactory.swift
git commit -m "Monad: build PositronicKit's TimelineManager/ToolRouter through the facade, fixing a silent in-memory memoryStore divergence"
```

### Task 8: Verify Shuttle Is Unaffected

**Files:** none (verification only)

- [ ] **Step 1: Confirm `ShuttleShardAgentRunner.swift` still builds**

`Shuttle/Sources/ShuttleServer/Agents/ShuttleShardAgentRunner.swift` uses the flat per-store initializer and never references `timelineManager:`/`toolRouter:`, so it should be unaffected by removing those parameters (removing unused optional parameters and adding new ones with defaults is source-compatible for callers that don't name them).

Run: `cd Shuttle && swift build`
Expected: PASS with no code changes required.

- [ ] **Step 2: Run Shuttle's test suite**

Run: `swift test`
Expected: PASS

---

## Final Verification

- [ ] `cd PositronicKit && swift build && swift test` — PASS
- [ ] `cd Monad && swift build && swift test` — PASS
- [ ] `cd Shuttle && swift build && swift test` — PASS
- [ ] `grep -rn "timelineManager:\s*TimelineManager?\|toolRouter:\s*ToolRouter?" PositronicKit/Sources PositronicKit/Tests Monad/Sources Shuttle/Sources` finds no remaining override-style parameters on `PositronicKit`'s initializers.
