import Foundation
import PKShared

// MARK: - InMemoryMessageStore

/// Thread-safe in-memory message store for prototyping and development.
public actor InMemoryMessageStore: MessageStoreProtocol {
    private var messages: [ConversationMessage] = []

    public init() {}

    public func saveMessage(_ message: ConversationMessage) async throws {
        messages.append(message)
    }

    public func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] {
        messages.filter { $0.timelineId == timelineId }
    }

    public func deleteMessages(for timelineId: UUID) async throws {
        messages.removeAll { $0.timelineId == timelineId }
    }

    public func pruneMessages(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        0
    }

    public func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot] {
        messages
            .filter { $0.timelineId == timelineId && $0.role == "assistant" }
            .compactMap { msg in
                guard let data = msg.snapshotData else { return nil }
                return try? SerializationUtils.jsonDecoder.decode(TurnSnapshot.self, from: data)
            }
    }
}

// MARK: - InMemoryTimelinePersistence

/// Thread-safe in-memory timeline persistence for prototyping and development.
public actor InMemoryTimelinePersistence: TimelinePersistenceProtocol {
    private var timelines: [Timeline] = []

    public init() {}

    public func saveTimeline(_ timeline: Timeline) async throws {
        if let index = timelines.firstIndex(where: { $0.id == timeline.id }) {
            timelines[index] = timeline
        } else {
            timelines.append(timeline)
        }
    }

    public func fetchTimeline(id: UUID) async throws -> Timeline? {
        timelines.first { $0.id == id }
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
        if includeArchived {
            return timelines
        } else {
            return timelines.filter { !$0.isArchived }
        }
    }

    public func deleteTimeline(id: UUID) async throws {
        timelines.removeAll { $0.id == id }
    }

    public func pruneTimelines(olderThan _: TimeInterval, excluding _: [UUID], dryRun _: Bool) async throws -> Int {
        0
    }
}

// MARK: - InMemoryWorkspacePersistence

/// Thread-safe in-memory workspace persistence for prototyping and development.
public actor InMemoryWorkspacePersistence: WorkspacePersistenceProtocol {
    private var workspaces: [WorkspaceReference] = []

    public init() {}

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    public func fetchWorkspace(id: UUID, includeTools _: Bool = false) async throws -> WorkspaceReference? {
        workspaces.first { $0.id == id }
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        workspaces
    }

    public func deleteWorkspace(id: UUID) async throws {
        workspaces.removeAll { $0.id == id }
    }
}

// MARK: - InMemoryMemoryStore

/// Thread-safe in-memory memory store for prototyping and development.
public actor InMemoryMemoryStore: MemoryStoreProtocol {
    private var memories: [Memory] = []

    public init() {}

    public func saveMemory(_ memory: Memory, policy _: MemorySavePolicy) async throws -> UUID {
        memories.append(memory)
        return memory.id
    }

    public func fetchMemory(id: UUID) async throws -> Memory? {
        memories.first { $0.id == id }
    }

    public func fetchAllMemories() async throws -> [Memory] {
        memories
    }

    public func searchMemories(query: String) async throws -> [Memory] {
        memories.filter { $0.title.contains(query) || $0.content.contains(query) }
    }

    public func searchMemories(embedding _: [Double], limit _: Int, minSimilarity _: Double) async throws -> [(memory: Memory, similarity: Double)] {
        []
    }

    public func searchMemories(matchingAnyTag tags: [String]) async throws -> [Memory] {
        memories.filter { memory in
            !Set(memory.tagArray).intersection(tags).isEmpty
        }
    }

    public func deleteMemory(id: UUID) async throws {
        memories.removeAll { $0.id == id }
    }

    public func updateMemory(_ memory: Memory) async throws {
        if let index = memories.firstIndex(where: { $0.id == memory.id }) {
            memories[index] = memory
        }
    }

    public func updateMemoryEmbedding(id: UUID, newEmbedding: [Double]) async throws {
        if let index = memories.firstIndex(where: { $0.id == id }) {
            var memory = memories[index]
            if let data = try? JSONEncoder().encode(newEmbedding) {
                memory.embedding = String(data: data, encoding: .utf8) ?? ""
                memories[index] = memory
            }
        }
    }

    public func vacuumMemories(threshold _: Double) async throws -> Int {
        0
    }

    public func pruneMemories(matching _: String, dryRun _: Bool) async throws -> Int {
        0
    }

    public func pruneMemories(olderThan _: TimeInterval, dryRun _: Bool) async throws -> Int {
        0
    }
}

// MARK: - InMemoryToolPersistence

/// Thread-safe in-memory tool persistence for prototyping and development.
public actor InMemoryToolPersistence: ToolPersistenceProtocol {
    private var workspaces: [WorkspaceReference] = []

    public init() {}

    public func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            var workspace = workspaces[index]
            workspace.tools.append(tool)
            workspaces[index] = workspace
        } else {
            throw ToolError.workspaceNotFound(workspaceId)
        }
    }

    public func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            var workspace = workspaces[index]
            workspace.tools = tools
            workspaces[index] = workspace
        } else {
            throw ToolError.workspaceNotFound(workspaceId)
        }
    }

    public func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference] {
        workspaces.filter { workspaceIds.contains($0.id) }.flatMap(\.tools)
    }

    public func fetchOriginTools(originId: UUID) async throws -> [ToolReference] {
        workspaces.filter { $0.originId == originId }.flatMap(\.tools)
    }

    public func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID? {
        for workspace in workspaces where workspaceIds.contains(workspace.id) {
            if workspace.tools.contains(where: { $0.toolId == toolId }) {
                return workspace.id
            }
        }
        return nil
    }

    public func fetchToolSource(
        toolId: String, workspaceIds: [UUID], primaryWorkspaceId: UUID?
    ) async throws -> String? {
        guard let wsId = try await findWorkspaceId(forToolId: toolId, in: workspaceIds),
              let workspace = workspaces.first(where: { $0.id == wsId })
        else { return nil }

        if workspace.location == .attached {
            return "Additional Workspace"
        } else if workspace.id == primaryWorkspaceId {
            return "Primary Workspace"
        } else {
            return "Workspace: \(workspace.uri.description)"
        }
    }
}

// MARK: - InMemoryAgentInstanceStore

/// Thread-safe in-memory agent instance store for prototyping and development.
public actor InMemoryAgentInstanceStore: AgentInstanceStoreProtocol {
    private var instances: [AgentInstance] = []

    public init() {}

    public func saveAgentInstance(_ instance: AgentInstance) async throws {
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = instance
        } else {
            instances.append(instance)
        }
    }

    public func fetchAgentInstance(id: UUID) async throws -> AgentInstance? {
        instances.first { $0.id == id }
    }

    public func fetchAllAgentInstances() async throws -> [AgentInstance] {
        instances
    }

    public func deleteAgentInstance(id: UUID) async throws {
        instances.removeAll { $0.id == id }
    }

    public func fetchTimelines(attachedToAgent _: UUID) async throws -> [Timeline] {
        []
    }
}

// MARK: - InMemoryRequestOriginStore

/// Thread-safe in-memory request-origin store for prototyping and development.
public actor InMemoryRequestOriginStore: RequestOriginStoreProtocol {
    private var origins: [RequestOriginIdentity] = []

    public init() {}

    public func saveOrigin(_ origin: RequestOriginIdentity) async throws {
        if let index = origins.firstIndex(where: { $0.id == origin.id }) {
            origins[index] = origin
        } else {
            origins.append(origin)
        }
    }

    public func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity? {
        origins.first { $0.id == id }
    }

    public func fetchAllOrigins() async throws -> [RequestOriginIdentity] {
        origins
    }

    public func deleteOrigin(id: UUID) async throws -> Bool {
        let count = origins.count
        origins.removeAll { $0.id == id }
        return origins.count < count
    }

}

// MARK: - InMemoryAgentTemplateStore

/// Thread-safe in-memory agent template store for prototyping and development.
public actor InMemoryAgentTemplateStore: AgentTemplateStoreProtocol {
    private var templates: [AgentTemplate] = []

    public init() {}

    public func saveAgentTemplate(_ template: AgentTemplate) async throws {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
        } else {
            templates.append(template)
        }
    }

    public func fetchAgentTemplate(id: UUID) async throws -> AgentTemplate? {
        templates.first { $0.id == id }
    }

    public func fetchAgentTemplate(key: String) async throws -> AgentTemplate? {
        if key == "default" {
            return templates.first
        }
        if let uuid = UUID(uuidString: key) {
            return templates.first { $0.id == uuid }
        }
        return nil
    }

    public func fetchAllAgentTemplates() async throws -> [AgentTemplate] {
        templates
    }

    public func hasAgentTemplate(id: String) async -> Bool {
        if let uuid = UUID(uuidString: id) {
            return templates.contains { $0.id == uuid }
        }
        return false
    }
}
