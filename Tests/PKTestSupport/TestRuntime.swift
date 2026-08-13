import Foundation
import PKShared
import PKUtilities
import PositronicKit

    /// Explicit test composition root for PositronicKit runtime tests.
    ///
    /// `TestRuntime` replaces the former ambient dependency-injection machinery with plain
    /// constructor injection: every store, manager, and service is wired
    /// from a single `MockPersistenceService` so a test can rely on one coherent, shared
    /// persistence backing across the thread manager, tool router, and `PositronicKit`.
    ///
    /// Construct one per test with a unique `workspaceRoot`, then read its fields directly or
    /// access `positronicKit` for a fully-wired facade. `threadManager`, `toolRouter`, and
    /// `agentInstanceManager` return the exact facade-owned instances. `agentWorkspaceService`
    /// and `workspaceManager` remain separately exposed compatibility helpers using the supplied
    /// persistence and workspace factory.
    public struct TestRuntime: Sendable {
        public let persistence: MockPersistenceService
        public let llm: MockLLMService
        public let embedding: MockEmbeddingService

        private let core: PositronicKit

        public var threadManager: ThreadManager {
            core.threadManager
        }

        @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
        public var timelineManager: ThreadManager {
            core.threadManager
        }

        public var threadPersistence: any ThreadPersistenceProtocol {
            persistence
        }

        public var toolRouter: ToolRouter {
            core.toolRouter
        }

        public let agentWorkspaceService: DefaultWorkspaceCatalog
        /// The facade-owned manager; identical (`===`) to `positronicKit.agentInstanceManager`.
        public var agentInstanceManager: AgentInstanceManager {
            core.agentInstanceManager
        }
        public let workspaceManager: DefaultWorkspaceResolver

        /// Creates a fully-wired runtime. All collaborators default to values built from the
        /// supplied `persistence`, so the whole graph shares one backing store. The
        /// `PositronicKit` facade is the sole place that builds the `ThreadManager` and
        /// `ToolRouter` and `AgentInstanceManager` it wraps; the corresponding properties simply
        /// read those instances back.
        ///
        /// - Parameters:
        ///   - workspaceRoot: Unique root directory for this runtime's workspaces.
        ///   - persistence: Backing store shared by every collaborator. Defaults to a fresh mock.
        ///   - llm: Mock LLM service. Defaults to a fresh mock.
        ///   - embedding: Mock embedding service. Defaults to a fresh mock.
        ///   - workspaceCreator: Workspace factory for the thread manager. Defaults to `MockWorkspaceCreator`.
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
                    threadPersistence: persistence,
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
