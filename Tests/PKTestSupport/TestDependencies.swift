import Dependencies
import Foundation
import PositronicKit
import PKShared

#if DEBUG

    // MARK: - MockContext

    /// Provides access to the mock services created by `TestDependencies`.
    public struct MockContext: Sendable {
        public let persistence: MockPersistenceService
        public let llm: MockLLMService
        public let embedding: MockEmbeddingService

        public init(
            persistence: MockPersistenceService,
            llm: MockLLMService,
            embedding: MockEmbeddingService
        ) {
            self.persistence = persistence
            self.llm = llm
            self.embedding = embedding
        }

        /// Builds a `MonadCore` from the mock services in this context.
        /// Must be called inside a `withDependencies` scope that has a `TimelineManager` configured.
        public func buildCoreChat() -> MonadCore {
            @Dependency(\.timelineManager) var timelineManager
            return MonadCore(
                llmService: llm,
                persistence: .init(
                    messageStore: persistence,
                    timelinePersistence: persistence,
                    workspacePersistence: persistence,
                    memoryStore: persistence,
                    toolPersistence: persistence,
                    agentInstanceStore: persistence,
                    clientStore: persistence,
                    agentTemplateStore: persistence
                ),
                embeddingService: embedding,
                timelineManager: timelineManager
            )
        }
    }

    // MARK: - TestDependencies

    /// Fluent builder that replaces the 8-line persistence dependency boilerplate
    /// repeated across test files with a single `.withMocks()` call.
    ///
    /// ```swift
    /// try await TestDependencies()
    ///     .withMocks()
    ///     .run { mocks in
    ///         let manager = TimelineManager(workspaceRoot: root)
    ///         // ...
    ///     }
    /// ```
    public struct TestDependencies: Sendable {
        private var overrides: [@Sendable (inout DependencyValues) -> Void] = []
        private var mockPersistence: MockPersistenceService?
        private var mockLLM: MockLLMService?
        private var mockEmbedding: MockEmbeddingService?

        public init() {}

        // MARK: - Chainable Configuration

        /// Registers all standard mock services: persistence (8 keys), LLM, and embedding.
        public func withMocks(
            persistence: MockPersistenceService? = nil,
            llm: MockLLMService? = nil,
            embedding: MockEmbeddingService? = nil
        ) -> TestDependencies {
            let persistence = persistence ?? MockPersistenceService()
            let llm = llm ?? MockLLMService()
            let embedding = embedding ?? MockEmbeddingService()

            var copy = self
            copy.mockPersistence = persistence
            copy.mockLLM = llm
            copy.mockEmbedding = embedding
            copy.overrides.append { deps in
                deps.persistenceService = persistence
                deps.embeddingService = embedding
                deps.llmService = llm
            }
            return copy
        }

        /// Adds a `TimelineManager` dependency with the given workspace root.
        public func withTimelineManager(
            workspaceRoot: URL,
            workspaceCreator: WorkspaceCreating? = nil
        ) -> TestDependencies {
            let creator = workspaceCreator ?? MockWorkspaceCreator()
            var copy = self
            copy.overrides.append { deps in
                deps.timelineManager = TimelineManager(
                    workspaceRoot: workspaceRoot,
                    workspaceCreator: creator
                )
            }
            return copy
        }

        /// Adds a `ToolRouter` dependency.
        public func withToolRouter() -> TestDependencies {
            var copy = self
            copy.overrides.append { deps in
                deps.toolRouter = ToolRouter()
            }
            return copy
        }

        /// Adds `TimelineManager` and `ToolRouter` in one call.
        public func withOrchestration(workspaceRoot: URL) -> TestDependencies {
            withTimelineManager(workspaceRoot: workspaceRoot)
                .withToolRouter()
        }

        /// Adds an arbitrary dependency override.
        public func with(_ override: @escaping @Sendable (inout DependencyValues) -> Void) -> TestDependencies {
            var copy = self
            copy.overrides.append(override)
            return copy
        }

        // MARK: - Execution

        /// Runs the operation inside `withDependencies` with all accumulated overrides.
        @discardableResult
        public func run<T: Sendable>(
            _ operation: @Sendable (MockContext) async throws -> T
        ) async throws -> T {
            let persistence = mockPersistence ?? MockPersistenceService()
            let llm = mockLLM ?? MockLLMService()
            let embedding = mockEmbedding ?? MockEmbeddingService()
            let context = MockContext(persistence: persistence, llm: llm, embedding: embedding)
            let capturedOverrides = overrides

            return try await withDependencies {
                for override in capturedOverrides {
                    override(&$0)
                }
            } operation: {
                try await operation(context)
            }
        }

        /// Runs the operation without providing a `MockContext` — useful when you only
        /// need the dependency scope and don't need direct access to mock instances.
        @discardableResult
        public func run<T: Sendable>(
            _ operation: @Sendable () async throws -> T
        ) async throws -> T {
            let capturedOverrides = overrides

            return try await withDependencies {
                for override in capturedOverrides {
                    override(&$0)
                }
            } operation: {
                try await operation()
            }
        }
    }

#endif
