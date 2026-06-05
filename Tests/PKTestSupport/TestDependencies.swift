import Foundation
import PositronicKit
import PKShared

#if DEBUG

public struct TestRuntimeOverrides: Sendable {
    public var timelineManager: TimelineManager?
    public var toolRouter: ToolRouter?
    public var agentWorkspaceService: (any AgentWorkspaceServiceProtocol)?
    public var agentInstanceManager: (any AgentInstanceManagerProtocol)?
    public var continuousClock: ContinuousClock?

    public init() {}
}

public struct MockContext: Sendable {
    public let persistence: MockPersistenceService
    public let llm: MockLLMService
    public let embedding: MockEmbeddingService
    public let overrides: TestRuntimeOverrides

    public init(
        persistence: MockPersistenceService,
        llm: MockLLMService,
        embedding: MockEmbeddingService,
        overrides: TestRuntimeOverrides
    ) {
        self.persistence = persistence
        self.llm = llm
        self.embedding = embedding
        self.overrides = overrides
    }

    public func buildCoreChat() -> PositronicKitCore {
        let timelineManager = overrides.timelineManager ?? TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: FileManager.default.temporaryDirectory
        )
        let toolRouter = overrides.toolRouter ?? ToolRouter(
            timelineManager: timelineManager,
            messageStore: persistence
        )

        return PositronicKitCore(
            llmService: llm,
            persistence: .init(
                messageStore: persistence,
                timelinePersistence: persistence,
                workspacePersistence: persistence,
                memoryStore: persistence,
                toolPersistence: persistence,
                agentInstanceStore: persistence,
                requestOriginStore: persistence,
                agentTemplateStore: persistence
            ),
            embeddingService: embedding,
            runtime: .init(
                timelineManager: timelineManager,
                toolRouter: toolRouter
            )
        )
    }
}

public struct TestDependencies: Sendable {
    private var mockPersistence: MockPersistenceService?
    private var mockLLM: MockLLMService?
    private var mockEmbedding: MockEmbeddingService?
    private var overrides = TestRuntimeOverrides()

    public init() {}

    public func withMocks(
        persistence: MockPersistenceService? = nil,
        llm: MockLLMService? = nil,
        embedding: MockEmbeddingService? = nil
    ) -> TestDependencies {
        var copy = self
        copy.mockPersistence = persistence ?? MockPersistenceService()
        copy.mockLLM = llm ?? MockLLMService()
        copy.mockEmbedding = embedding ?? MockEmbeddingService()
        return copy
    }

    public func withTimelineManager(
        workspaceRoot: URL,
        workspaceCreator: WorkspaceCreating? = nil
    ) -> TestDependencies {
        var copy = self
        let persistence = copy.mockPersistence ?? MockPersistenceService()
        copy.mockPersistence = persistence
        copy.overrides.timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: workspaceRoot,
            workspaceCreator: workspaceCreator ?? MockWorkspaceCreator()
        )
        return copy
    }

    public func withToolRouter() -> TestDependencies {
        var copy = self
        let persistence = copy.mockPersistence ?? MockPersistenceService()
        copy.mockPersistence = persistence
        let timelineManager = copy.overrides.timelineManager ?? TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: FileManager.default.temporaryDirectory
        )
        copy.overrides.timelineManager = timelineManager
        copy.overrides.toolRouter = ToolRouter(
            timelineManager: timelineManager,
            messageStore: persistence
        )
        return copy
    }

    public func withOrchestration(workspaceRoot: URL) -> TestDependencies {
        withTimelineManager(workspaceRoot: workspaceRoot).withToolRouter()
    }

    public func with(
        _ override: @escaping @Sendable (inout TestRuntimeOverrides) -> Void
    ) -> TestDependencies {
        var copy = self
        override(&copy.overrides)
        return copy
    }

    @discardableResult
    public func run<T: Sendable>(
        _ operation: @Sendable (MockContext) async throws -> T
    ) async throws -> T {
        let persistence = mockPersistence ?? MockPersistenceService()
        let llm = mockLLM ?? MockLLMService()
        let embedding = mockEmbedding ?? MockEmbeddingService()
        let context = MockContext(
            persistence: persistence,
            llm: llm,
            embedding: embedding,
            overrides: overrides
        )
        return try await operation(context)
    }

    @discardableResult
    public func run<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await operation()
    }
}

#endif
