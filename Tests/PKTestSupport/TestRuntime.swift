import Foundation
import PKShared
import PKUtilities
import PositronicKit

#if DEBUG

    /// Explicit test composition root for PositronicKit runtime tests.
    ///
    /// `TestRuntime` replaces the former ambient dependency-injection machinery with plain
    /// constructor injection: every store, manager, and service is wired
    /// from a single `MockPersistenceService` so a test can rely on one coherent, shared
    /// persistence backing across the timeline manager, tool router, and `PositronicKit`.
    ///
    /// Construct one per test with a unique `workspaceRoot`, then read its fields directly or
    /// access `positronicKit` for a fully-wired facade.
    public struct TestRuntime: Sendable {
        public let persistence: MockPersistenceService
        public let llm: MockLLMService
        public let embedding: MockEmbeddingService

        private let core: PositronicKit

        public var timelineManager: TimelineManager {
            core.timelineManager
        }

        public var toolRouter: ToolRouter {
            core.toolRouter
        }

        public let agentWorkspaceService: DefaultWorkspaceCatalog
        public let agentInstanceManager: AgentInstanceManager
        public let workspaceManager: DefaultWorkspaceResolver

        /// Creates a fully-wired runtime. All collaborators default to values built from the
        /// supplied `persistence`, so the whole graph shares one backing store. The
        /// `PositronicKit` facade is the sole place that builds the `TimelineManager` and
        /// `ToolRouter` it wraps; `timelineManager`/`toolRouter` simply read those back.
        ///
        /// - Parameters:
        ///   - workspaceRoot: Unique root directory for this runtime's workspaces.
        ///   - persistence: Backing store shared by every collaborator. Defaults to a fresh mock.
        ///   - llm: Mock LLM service. Defaults to a fresh mock.
        ///   - embedding: Mock embedding service. Defaults to a fresh mock.
        ///   - workspaceCreator: Workspace factory for the timeline manager. Defaults to `MockWorkspaceCreator`.
        public init(
            workspaceRoot: URL,
            persistence: MockPersistenceService = MockPersistenceService(),
            llm: MockLLMService = MockLLMService(),
            embedding: MockEmbeddingService = MockEmbeddingService(),
            workspaceCreator: any WorkspaceFactory = MockWorkspaceCreator()
        ) {
            self.persistence = persistence
            self.llm = llm
            self.embedding = embedding

            core = PositronicKit(configuration: .init(provider: .init(languageModel: llm, embeddingService: embedding), persistence: .init(
                    messageStore: persistence,
                    timelinePersistence: persistence,
                    workspacePersistence: persistence,
                    memoryStore: persistence,
                    toolPersistence: persistence,
                    agentInstanceStore: persistence,
                    requestOriginStore: persistence
                ), runtime: .init(
                    workspaceCreator: workspaceCreator,
                    workspaceRoot: workspaceRoot
                )))

            let agentWorkspaceService = DefaultWorkspaceCatalog(
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
            workspaceManager = DefaultWorkspaceResolver(
                repository: agentWorkspaceService,
                workspaceCreator: workspaceCreator
            )
        }

        /// The `PositronicKit` facade wired to this runtime's stores, managers, and services.
        public var positronicKit: PositronicKit {
            core
        }

        /// Returns the `PositronicKit` facade wired to this runtime.
        @available(*, deprecated, renamed: "positronicKit")
        public func buildCore() -> PositronicKit {
            positronicKit
        }
    }

#endif
