import Dependencies
import Foundation
import PositronicKit
import PKShared

private enum TimelineManagerKey: DependencyKey {
    static var liveValue: TimelineManager {
        TimelineManager(workspaceRoot: FileManager.default.temporaryDirectory)
    }
    static var testValue: TimelineManager { liveValue }
}

private enum ToolRouterKey: DependencyKey {
    static var liveValue: ToolRouter {
        ToolRouter(
            timelineManager: DependencyValues._current.timelineManager,
            messageStore: DependencyValues._current.messageStore
        )
    }
    static var testValue: ToolRouter { liveValue }
}

private enum MemoryStoreKey: DependencyKey {
    static let liveValue: any MemoryStoreProtocol = InMemoryMemoryStore()
    static let testValue: any MemoryStoreProtocol = InMemoryMemoryStore()
}

private enum MessageStoreKey: DependencyKey {
    static let liveValue: any MessageStoreProtocol = InMemoryMessageStore()
    static let testValue: any MessageStoreProtocol = InMemoryMessageStore()
}

private enum TimelinePersistenceKey: DependencyKey {
    static let liveValue: any TimelinePersistenceProtocol = InMemoryTimelinePersistence()
    static let testValue: any TimelinePersistenceProtocol = InMemoryTimelinePersistence()
}

private enum WorkspacePersistenceKey: DependencyKey {
    static let liveValue: any WorkspacePersistenceProtocol = InMemoryWorkspacePersistence()
    static let testValue: any WorkspacePersistenceProtocol = InMemoryWorkspacePersistence()
}

private enum ToolPersistenceKey: DependencyKey {
    static let liveValue: any ToolPersistenceProtocol = InMemoryToolPersistence()
    static let testValue: any ToolPersistenceProtocol = InMemoryToolPersistence()
}

private enum AgentTemplateStoreKey: DependencyKey {
    static let liveValue: any AgentTemplateStoreProtocol = InMemoryAgentTemplateStore()
    static let testValue: any AgentTemplateStoreProtocol = InMemoryAgentTemplateStore()
}

private enum AgentInstanceStoreKey: DependencyKey {
    static let liveValue: any AgentInstanceStoreProtocol = InMemoryAgentInstanceStore()
    static let testValue: any AgentInstanceStoreProtocol = InMemoryAgentInstanceStore()
}

private enum RequestOriginStoreKey: DependencyKey {
    static let liveValue: any RequestOriginStoreProtocol = InMemoryRequestOriginStore()
    static let testValue: any RequestOriginStoreProtocol = InMemoryRequestOriginStore()
}

private enum AgentWorkspaceServiceKey: DependencyKey {
    static let liveValue: any AgentWorkspaceServiceProtocol = AgentWorkspaceService(
        workspaceRoot: FileManager.default.temporaryDirectory,
        workspacePersistence: DependencyValues._current.workspacePersistence
    )
    static let testValue: any AgentWorkspaceServiceProtocol = liveValue
}

private enum AgentInstanceManagerKey: DependencyKey {
    static var liveValue: any AgentInstanceManagerProtocol {
        AgentInstanceManager(
            repository: DependencyValues._current.agentWorkspaceService,
            stores: .init(
                instanceStore: DependencyValues._current.agentInstanceStore,
                timelineStore: DependencyValues._current.timelinePersistence,
                messageStore: DependencyValues._current.messageStore,
                workspaceStore: DependencyValues._current.workspacePersistence
            )
        )
    }
}

private enum WorkspaceManagerKey: DependencyKey {
    static var liveValue: any WorkspaceManagerProtocol {
        WorkspaceManager(
            repository: DependencyValues._current.agentWorkspaceService,
            workspaceCreator: NullWorkspaceCreator()
        )
    }
}

private enum EmbeddingServiceKey: DependencyKey {
    static let liveValue: any EmbeddingServiceProtocol = NoOpEmbeddingService()
    static let testValue: any EmbeddingServiceProtocol = NoOpEmbeddingService()
}

private enum LLMServiceKey: DependencyKey {
    static let liveValue: any LLMServiceProtocol = UnconfiguredLLMService()
    static let testValue: any LLMServiceProtocol = UnconfiguredLLMService()
}

public extension DependencyValues {
    var timelineManager: TimelineManager {
        get { self[TimelineManagerKey.self] }
        set { self[TimelineManagerKey.self] = newValue }
    }

    var toolRouter: ToolRouter {
        get { self[ToolRouterKey.self] }
        set { self[ToolRouterKey.self] = newValue }
    }

    var memoryStore: any MemoryStoreProtocol {
        get { self[MemoryStoreKey.self] }
        set { self[MemoryStoreKey.self] = newValue }
    }

    var messageStore: any MessageStoreProtocol {
        get { self[MessageStoreKey.self] }
        set { self[MessageStoreKey.self] = newValue }
    }

    var timelinePersistence: any TimelinePersistenceProtocol {
        get { self[TimelinePersistenceKey.self] }
        set { self[TimelinePersistenceKey.self] = newValue }
    }

    var workspacePersistence: any WorkspacePersistenceProtocol {
        get { self[WorkspacePersistenceKey.self] }
        set { self[WorkspacePersistenceKey.self] = newValue }
    }

    var toolPersistence: any ToolPersistenceProtocol {
        get { self[ToolPersistenceKey.self] }
        set { self[ToolPersistenceKey.self] = newValue }
    }

    var agentTemplateStore: any AgentTemplateStoreProtocol {
        get { self[AgentTemplateStoreKey.self] }
        set { self[AgentTemplateStoreKey.self] = newValue }
    }

    var agentInstanceStore: any AgentInstanceStoreProtocol {
        get { self[AgentInstanceStoreKey.self] }
        set { self[AgentInstanceStoreKey.self] = newValue }
    }

    var requestOriginStore: any RequestOriginStoreProtocol {
        get { self[RequestOriginStoreKey.self] }
        set { self[RequestOriginStoreKey.self] = newValue }
    }

    var agentWorkspaceService: any AgentWorkspaceServiceProtocol {
        get { self[AgentWorkspaceServiceKey.self] }
        set { self[AgentWorkspaceServiceKey.self] = newValue }
    }

    var agentInstanceManager: any AgentInstanceManagerProtocol {
        get { self[AgentInstanceManagerKey.self] }
        set { self[AgentInstanceManagerKey.self] = newValue }
    }

    var workspaceManager: any WorkspaceManagerProtocol {
        get { self[WorkspaceManagerKey.self] }
        set { self[WorkspaceManagerKey.self] = newValue }
    }

    var embeddingService: any EmbeddingServiceProtocol {
        get { self[EmbeddingServiceKey.self] }
        set { self[EmbeddingServiceKey.self] = newValue }
    }

    var llmService: any LLMServiceProtocol {
        get { self[LLMServiceKey.self] }
        set { self[LLMServiceKey.self] = newValue }
    }

    var persistenceService: MockPersistenceService {
        get { fatalError("persistenceService is write-only in tests") }
        set {
            timelinePersistence = newValue
            workspacePersistence = newValue
            memoryStore = newValue
            messageStore = newValue
            requestOriginStore = newValue
            toolPersistence = newValue
            agentTemplateStore = newValue
            agentInstanceStore = newValue
        }
    }
}
