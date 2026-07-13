import Foundation
import PKShared
import PKUtilities
import PositronicKit

/// Composite in-memory test double for the full persistence surface (memories, messages,
/// timelines, agent templates, workspaces, tools, request origins, agent instances,
/// health), delegating each protocol area to its own focused mock (``MockMemoryStore``,
/// ``MockMessageStore``, ``MockTimelinePersistence``, ``MockAgentTemplateStore``,
/// ``MockWorkspacePersistence``, ``MockToolPersistence``) so a test can construct a single
/// object instead of wiring up every store protocol separately.
///
/// Configurable: `mockHealthStatus`/`mockHealthDetails`; `saveOriginMock`/`fetchOriginMock`/
/// `fetchAllOriginsMock`/`deleteOriginMock` (closures overriding `RequestOriginStoreProtocol`
/// behavior — unset closures make origin operations no-ops/return empty). Inspectable:
/// `memories`, `searchResults`, `messages`, `timelines`, `agentTemplates`, `workspaces`,
/// `agentInstances` all forward to the underlying focused mocks. `resetDatabase()` clears
/// every backing store.
public final class MockPersistenceService: MemoryStoreProtocol, MessageStoreProtocol, TimelinePersistenceProtocol, WorkspaceStore, AgentTemplateStoreProtocol, RequestOriginStoreProtocol, ToolPersistenceProtocol, AgentInstanceStoreProtocol, HealthCheckable, @unchecked Sendable {
    private let memoriesMock = MockMemoryStore()
    private let messagesMock = MockMessageStore()
    private let timelinesMock = MockTimelinePersistence()
    private let agentTemplatesMock = MockAgentTemplateStore()
    private let workspacesMock = MockWorkspacePersistence()
    private let toolsMock = MockToolPersistence()

    public var mockHealthStatus: HealthStatus = .ok
    public var mockHealthDetails: [String: String]? = ["mock": "true"]

    // Mocks
    public var saveOriginMock: ((RequestOriginIdentity) async throws -> Void)?
    public var fetchOriginMock: ((UUID) async throws -> RequestOriginIdentity?)?
    public var fetchAllOriginsMock: (() async throws -> [RequestOriginIdentity])?
    public var deleteOriginMock: ((UUID) async throws -> Bool)?

    public init() {}

    public func getHealthDetails() async -> [String: String]? {
        mockHealthDetails
    }

    public func checkHealth() async -> HealthStatus {
        mockHealthStatus
    }

    // MARK: - MemoryStoreProtocol

    public var memories: [Memory] {
        get { memoriesMock.memories }
        set { memoriesMock.memories = newValue }
    }

    public var searchResults: [(memory: Memory, similarity: Double)] {
        get { memoriesMock.searchResults }
        set { memoriesMock.searchResults = newValue }
    }

    public func saveMemory(_ memory: Memory, policy: MemorySavePolicy) async throws -> UUID {
        try await memoriesMock.saveMemory(memory, policy: policy)
    }

    public func fetchMemory(id: UUID) async throws -> Memory? {
        try await memoriesMock.fetchMemory(id: id)
    }

    public func fetchAllMemories() async throws -> [Memory] {
        try await memoriesMock.fetchAllMemories()
    }

    public func searchMemories(query: String) async throws -> [Memory] {
        try await memoriesMock.searchMemories(query: query)
    }

    public func searchMemories(embedding: [Double], limit: Int, minSimilarity: Double) async throws -> [(memory: Memory, similarity: Double)] {
        try await memoriesMock.searchMemories(embedding: embedding, limit: limit, minSimilarity: minSimilarity)
    }

    public func searchMemories(matchingAnyTag tags: [String]) async throws -> [Memory] {
        try await memoriesMock.searchMemories(matchingAnyTag: tags)
    }

    public func deleteMemory(id: UUID) async throws {
        try await memoriesMock.deleteMemory(id: id)
    }

    public func updateMemory(_ memory: Memory) async throws {
        try await memoriesMock.updateMemory(memory)
    }

    public func updateMemoryEmbedding(id: UUID, newEmbedding: [Double]) async throws {
        try await memoriesMock.updateMemoryEmbedding(id: id, newEmbedding: newEmbedding)
    }

    public func vacuumMemories(threshold: Double) async throws -> Int {
        try await memoriesMock.vacuumMemories(threshold: threshold)
    }

    public func pruneMemories(matching query: String, dryRun: Bool) async throws -> Int {
        try await memoriesMock.pruneMemories(matching: query, dryRun: dryRun)
    }

    public func pruneMemories(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        try await memoriesMock.pruneMemories(olderThan: timeInterval, dryRun: dryRun)
    }

    // MARK: - MessageStoreProtocol

    public var messages: [ConversationMessage] {
        get { messagesMock.messages }
        set { messagesMock.messages = newValue }
    }

    public func saveMessage(_ message: ConversationMessage) async throws {
        try await messagesMock.saveMessage(message)
    }

    public func fetchMessages(for timelineId: UUID) async throws -> [ConversationMessage] {
        try await messagesMock.fetchMessages(for: timelineId)
    }

    public func deleteMessages(for timelineId: UUID) async throws {
        try await messagesMock.deleteMessages(for: timelineId)
    }

    public func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        try await messagesMock.pruneMessages(olderThan: timeInterval, dryRun: dryRun)
    }

    public func fetchSnapshots(for timelineId: UUID) async throws -> [TurnSnapshot] {
        try await messagesMock.fetchSnapshots(for: timelineId)
    }

    // MARK: - TimelinePersistenceProtocol

    public var timelines: [Timeline] {
        get { timelinesMock.timelines }
        set { timelinesMock.timelines = newValue }
    }

    public func saveTimeline(_ timeline: Timeline) async throws {
        try await timelinesMock.saveTimeline(timeline)
    }

    public func fetchTimeline(id: UUID) async throws -> Timeline? {
        try await timelinesMock.fetchTimeline(id: id)
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [Timeline] {
        try await timelinesMock.fetchAllTimelines(includeArchived: includeArchived)
    }

    public func deleteTimeline(id: UUID) async throws {
        try await timelinesMock.deleteTimeline(id: id)
    }

    public func pruneTimelines(olderThan timeInterval: TimeInterval, excluding excludedTimelineIds: [UUID], dryRun: Bool) async throws -> Int {
        try await timelinesMock.pruneTimelines(olderThan: timeInterval, excluding: excludedTimelineIds, dryRun: dryRun)
    }

    // MARK: - AgentTemplateStoreProtocol

    public var agentTemplates: [AgentTemplate] {
        get { agentTemplatesMock.agentTemplates }
        set { agentTemplatesMock.agentTemplates = newValue }
    }

    public func saveAgentTemplate(_ agent: AgentTemplate) async throws {
        try await agentTemplatesMock.saveAgentTemplate(agent)
    }

    public func fetchAgentTemplate(id: UUID) async throws -> AgentTemplate? {
        try await agentTemplatesMock.fetchAgentTemplate(id: id)
    }

    public func fetchAgentTemplate(key: String) async throws -> AgentTemplate? {
        try await agentTemplatesMock.fetchAgentTemplate(key: key)
    }

    public func fetchAllAgentTemplates() async throws -> [AgentTemplate] {
        try await agentTemplatesMock.fetchAllAgentTemplates()
    }

    public func hasAgentTemplate(id: String) async -> Bool {
        await agentTemplatesMock.hasAgentTemplate(id: id)
    }

    // MARK: - WorkspaceStore

    public var workspaces: [WorkspaceReference] {
        get { workspacesMock.workspaces }
        set { workspacesMock.workspaces = newValue }
    }

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        try await workspacesMock.saveWorkspace(workspace)
        if let idx = toolsMock.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            toolsMock.workspaces[idx] = workspace
        } else {
            toolsMock.workspaces.append(workspace)
        }
    }

    public func fetchWorkspace(id: UUID, includeTools: Bool = false) async throws -> WorkspaceReference? {
        var ws = try await workspacesMock.fetchWorkspace(id: id, includeTools: includeTools)
        if includeTools, ws != nil {
            if let toolsWs = toolsMock.workspaces.first(where: { $0.id == id }) {
                ws?.tools = toolsWs.tools
            }
        }
        return ws
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        try await workspacesMock.fetchAllWorkspaces()
    }

    public func deleteWorkspace(id: UUID) async throws {
        try await workspacesMock.deleteWorkspace(id: id)
    }

    // MARK: - ToolPersistenceProtocol

    public func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws {
        try await toolsMock.addToolToWorkspace(workspaceId: workspaceId, tool: tool)
    }

    public func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws {
        try await toolsMock.syncTools(workspaceId: workspaceId, tools: tools)
    }

    public func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference] {
        try await toolsMock.fetchTools(forWorkspaces: workspaceIds)
    }

    public func fetchOriginTools(originId: UUID) async throws -> [ToolReference] {
        try await toolsMock.fetchOriginTools(originId: originId)
    }

    public func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID? {
        try await toolsMock.findWorkspaceId(forToolId: toolId, in: workspaceIds)
    }

    public func fetchToolSource(toolId: String, workspaceIds: [UUID], primaryWorkspaceId: UUID?) async throws -> String? {
        try await toolsMock.fetchToolSource(toolId: toolId, workspaceIds: workspaceIds, primaryWorkspaceId: primaryWorkspaceId)
    }

    // MARK: - RequestOriginStoreProtocol

    public func saveOrigin(_ origin: RequestOriginIdentity) async throws {
        if let mock = saveOriginMock { try await mock(origin) }
    }

    public func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity? {
        if let mock = fetchOriginMock { return try await mock(id) }
        return nil
    }

    public func fetchAllOrigins() async throws -> [RequestOriginIdentity] {
        if let mock = fetchAllOriginsMock { return try await mock() }
        return []
    }

    public func deleteOrigin(id: UUID) async throws -> Bool {
        if let mock = deleteOriginMock {
            return try await mock(id)
        }
        return false
    }

    // MARK: - AgentInstanceStoreProtocol

    public var agentInstances: [AgentInstance] = []

    public func saveAgentInstance(_ instance: AgentInstance) async throws {
        if let idx = agentInstances.firstIndex(where: { $0.id == instance.id }) {
            agentInstances[idx] = instance
        } else {
            agentInstances.append(instance)
        }
    }

    public func fetchAgentInstance(id: UUID) async throws -> AgentInstance? {
        agentInstances.first { $0.id == id }
    }

    public func fetchAllAgentInstances() async throws -> [AgentInstance] {
        agentInstances
    }

    public func deleteAgentInstance(id: UUID) async throws {
        agentInstances.removeAll { $0.id == id }
    }

    public func fetchTimelines(attachedToAgent agentInstanceId: UUID) async throws -> [Timeline] {
        timelines.filter { $0.attachedAgentInstanceId == agentInstanceId }
    }

    public func resetDatabase() async throws {
        memories = []
        searchResults = []
        messages = []
        timelines = []
        agentTemplates = []
        workspaces = []
        agentInstances = []
        toolsMock.workspaces = []
    }
}
