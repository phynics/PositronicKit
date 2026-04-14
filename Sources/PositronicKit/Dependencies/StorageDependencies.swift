import Dependencies
import Foundation
import PKShared

// MARK: - Dependency Keys

public enum DatabaseManagerKey: DependencyKey {
    public static let liveValue: any HealthCheckable = UnconfiguredDatabaseManager()
    public static let testValue: any HealthCheckable = UnconfiguredDatabaseManager()
}

public enum AgentInstanceStoreKey: DependencyKey {
    public static let liveValue: any AgentInstanceStoreProtocol = InMemoryAgentInstanceStore()
    public static let testValue: any AgentInstanceStoreProtocol = InMemoryAgentInstanceStore()
}

public enum ClientStoreKey: DependencyKey {
    public static let liveValue: any ClientStoreProtocol = InMemoryClientStore()
    public static let testValue: any ClientStoreProtocol = InMemoryClientStore()
}

public enum AgentTemplateStoreKey: DependencyKey {
    public static let liveValue: any AgentTemplateStoreProtocol = InMemoryAgentTemplateStore()
    public static let testValue: any AgentTemplateStoreProtocol = InMemoryAgentTemplateStore()
}

public enum MemoryStoreKey: DependencyKey {
    public static let liveValue: any MemoryStoreProtocol = InMemoryMemoryStore()
    public static let testValue: any MemoryStoreProtocol = InMemoryMemoryStore()
}

public enum MessageStoreKey: DependencyKey {
    public static let liveValue: any MessageStoreProtocol = InMemoryMessageStore()
    public static let testValue: any MessageStoreProtocol = InMemoryMessageStore()
}

public enum TimelinePersistenceKey: DependencyKey {
    public static let liveValue: any TimelinePersistenceProtocol = InMemoryTimelinePersistence()
    public static let testValue: any TimelinePersistenceProtocol = InMemoryTimelinePersistence()
}

public enum ToolPersistenceKey: DependencyKey {
    public static let liveValue: any ToolPersistenceProtocol = InMemoryToolPersistence()
    public static let testValue: any ToolPersistenceProtocol = InMemoryToolPersistence()
}

public enum WorkspacePersistenceKey: DependencyKey {
    public static let liveValue: any WorkspacePersistenceProtocol = InMemoryWorkspacePersistence()
    public static let testValue: any WorkspacePersistenceProtocol = InMemoryWorkspacePersistence()
}

public enum VectorStoreKey: DependencyKey {
    public static let liveValue: (any VectorStoreProtocol)? = nil
}

public enum KeyValueStoreKey: DependencyKey {
    public static let liveValue: any KeyValueStoreProtocol = InMemoryKeyValueStore()
    public static let testValue: any KeyValueStoreProtocol = InMemoryKeyValueStore()
}

// MARK: - Dependency Values

public extension DependencyValues {
    var databaseManager: any HealthCheckable {
        get { self[DatabaseManagerKey.self] }
        set { self[DatabaseManagerKey.self] = newValue }
    }

    var agentInstanceStore: any AgentInstanceStoreProtocol {
        get { self[AgentInstanceStoreKey.self] }
        set { self[AgentInstanceStoreKey.self] = newValue }
    }

    var clientStore: any ClientStoreProtocol {
        get { self[ClientStoreKey.self] }
        set { self[ClientStoreKey.self] = newValue }
    }

    var agentTemplateStore: any AgentTemplateStoreProtocol {
        get { self[AgentTemplateStoreKey.self] }
        set { self[AgentTemplateStoreKey.self] = newValue }
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

    var toolPersistence: any ToolPersistenceProtocol {
        get { self[ToolPersistenceKey.self] }
        set { self[ToolPersistenceKey.self] = newValue }
    }

    var workspacePersistence: any WorkspacePersistenceProtocol {
        get { self[WorkspacePersistenceKey.self] }
        set { self[WorkspacePersistenceKey.self] = newValue }
    }

    var vectorStore: (any VectorStoreProtocol)? {
        get { self[VectorStoreKey.self] }
        set { self[VectorStoreKey.self] = newValue }
    }

    var keyValueStore: any KeyValueStoreProtocol {
        get { self[KeyValueStoreKey.self] }
        set { self[KeyValueStoreKey.self] = newValue }
    }
}

// MARK: - Placeholder Implementations

public struct UnconfiguredDatabaseManager: HealthCheckable {
    public init() {}
    private func fail() -> Never {
        fatalError("DatabaseManager not configured.")
    }

    public func getHealthStatus() async -> HealthStatus {
        .down
    }

    public func getHealthDetails() async -> [String: String]? {
        ["error": "Unconfigured"]
    }

    public func checkHealth() async -> HealthStatus {
        .down
    }
}
