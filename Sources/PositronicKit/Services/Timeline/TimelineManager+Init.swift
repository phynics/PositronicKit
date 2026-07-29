import ErrorKit
import Foundation
import Logging
import PKShared
import PKUtilities

// MARK: - Initialization

extension TimelineManager {
    /// Designated initializer taking a `workspaceRoot` (legacy / backward-compatible).
    ///
    /// Maps to `.hostManaged(root: seedNotes: .default)`, preserving the pre-PKRR-029 behavior
    /// of callers that pass an explicit `workspaceRoot`.
    init(
        stores: Stores,
        workspaceRoot: URL,
        resolver: any WorkspaceResolver,
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        self.init(
            stores: stores,
            workspaceProfile: .hostManaged(root: workspaceRoot, seedNotes: .default),
            resolver: resolver,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }

    /// Public designated initializer: accepts a fully-formed `any WorkspaceResolver` directly.
    public init(
        stores: Stores,
        workspaceRoot: URL,
        resolver: any WorkspaceResolver,
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService()
    ) {
        self.init(
            stores: stores,
            workspaceProfile: .hostManaged(root: workspaceRoot, seedNotes: .default),
            resolver: resolver,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService
        )
    }

    /// Public designated initializer with an explicit workspace profile (PKRR-029).
    ///
    /// Use `.noWorkspace` for a side-effect-free default, `.ephemeralWorkspace` for a
    /// self-cleaning scratch directory, or `.hostManaged` to preserve the pre-PKRR-029
    /// explicit-`workspaceRoot` behavior.
    public init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        resolver: any WorkspaceResolver,
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService()
    ) {
        self.init(
            stores: stores,
            workspaceProfile: workspaceProfile,
            resolver: resolver,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: nil
        )
    }

    /// Convenience initializer that builds the bundled default `WorkspaceResolver` (local
    /// filesystem catalog + injected factory) via `WorkspaceResolverFactory`, preserving the
    /// prior `workspaceCreator:`-based construction ergonomics without TimelineManager itself
    /// composing `DefaultWorkspaceCatalog`/`DefaultWorkspaceResolver`.
    init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        let catalogRoot = workspaceProfile.catalogRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("positronickit-workspaces", isDirectory: true)
        self.init(
            stores: stores,
            workspaceProfile: workspaceProfile,
            resolver: WorkspaceResolverFactory.makeDefault(
                workspaceRoot: catalogRoot,
                workspaceStore: stores.workspaceStore,
                workspaceCreator: workspaceCreator
            ),
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }

    /// Convenience initializer (legacy `workspaceRoot` form). Maps to `.hostManaged`.
    init(
        stores: Stores,
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService(),
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        self.init(
            stores: stores,
            workspaceProfile: .hostManaged(root: workspaceRoot, seedNotes: .default),
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }

    public init(
        stores: Stores,
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService()
    ) {
        self.init(
            stores: stores,
            workspaceRoot: workspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: nil
        )
    }

    /// Public convenience initializer with an explicit workspace profile (PKRR-029).
    public init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        embeddingService: any EmbeddingServiceProtocol = NoOpEmbeddingService()
    ) {
        self.init(
            stores: stores,
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            embeddingService: embeddingService,
            promptHistoryRegistry: nil
        )
    }

    /// Public convenience initializer with an explicit workspace profile and in-memory stores.
    public init(
        workspaceProfile: WorkspaceProfile = .noWorkspace,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default
    ) {
        self.init(
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: nil
        )
    }

    public init(
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default
    ) {
        self.init(
            workspaceRoot: workspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: nil
        )
    }

    init(
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        self.init(
            stores: .init(
                timelineStore: InMemoryTimelinePersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: InMemoryWorkspacePersistence(),
                toolPersistence: InMemoryToolPersistence()
            ),
            workspaceRoot: workspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }

    init(
        workspaceProfile: WorkspaceProfile,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = [],
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        promptHistoryRegistry: TimelinePromptJournals? = nil,
        taskRegistry: TimelineTaskRegistry? = nil
    ) {
        self.init(
            stores: .init(
                timelineStore: InMemoryTimelinePersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: InMemoryWorkspacePersistence(),
                toolPersistence: InMemoryToolPersistence()
            ),
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }
}
