import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

// MARK: - Initialization

extension ThreadManager {
    /// Public designated initializer with an explicit workspace profile (PKRR-029).
    ///
    /// Use `.noWorkspace` for a side-effect-free default, `.ephemeralWorkspace` for a
    /// self-cleaning scratch directory, or `.hostManaged` for a host-owned directory.
    public init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        resolver: any WorkspaceResolver,
        runtimeToolPolicy: RuntimeToolPolicy = .default
    ) {
        self.init(
            stores: stores,
            workspaceProfile: workspaceProfile,
            resolver: resolver,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: nil
        )
    }

    /// Convenience initializer that builds the bundled default `WorkspaceResolver` (local
    /// filesystem catalog + injected factory) via `WorkspaceResolverFactory`, preserving the
    /// prior `workspaceCreator:`-based construction ergonomics without ThreadManager itself
    /// composing `DefaultWorkspaceCatalog`/`DefaultWorkspaceResolver`.
    init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        promptHistoryRegistry: ThreadPromptJournals? = nil,
        taskRegistry: ThreadTaskRegistry? = nil
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
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }

    /// Public convenience initializer with an explicit workspace profile (PKRR-029).
    public init(
        stores: Stores,
        workspaceProfile: WorkspaceProfile,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        runtimeToolPolicy: RuntimeToolPolicy = .default
    ) {
        self.init(
            stores: stores,
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: nil
        )
    }

    /// Public convenience initializer with an explicit workspace profile and in-memory stores.
    public init(
        workspaceProfile: WorkspaceProfile = .noWorkspace,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        runtimeToolPolicy: RuntimeToolPolicy = .default
    ) {
        self.init(
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: nil
        )
    }

    init(
        workspaceProfile: WorkspaceProfile,
        workspaceCreator: any WorkspaceFactory = NullWorkspaceCreator(),
        runtimeToolPolicy: RuntimeToolPolicy = .default,
        promptHistoryRegistry: ThreadPromptJournals? = nil,
        taskRegistry: ThreadTaskRegistry? = nil
    ) {
        let workspaceStore = InMemoryWorkspacePersistence()
        let runtimeRepository = InMemoryThreadRuntimeRepository()
        self.init(
            stores: .init(
                threadStore: runtimeRepository,
                messageStore: runtimeRepository,
                workspaceStore: workspaceStore,
                workspaceBindingRepository: workspaceStore,
                runtimeRepository: runtimeRepository,
                toolPersistence: InMemoryToolPersistence()
            ),
            workspaceProfile: workspaceProfile,
            workspaceCreator: workspaceCreator,
            runtimeToolPolicy: runtimeToolPolicy,
            promptHistoryRegistry: promptHistoryRegistry,
            taskRegistry: taskRegistry
        )
    }
}
