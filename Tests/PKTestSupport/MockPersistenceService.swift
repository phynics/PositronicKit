import Foundation
import PKContracts
import PKUtilities
import PositronicKit
import struct PositronicKit.Thread
import Synchronization

/// Composite in-memory test double for the full persistence surface (messages,
/// threads, agent templates, workspaces, tools, request origins, agents,
/// health), delegating each protocol area to its own focused mock,
/// ``MockMessageStore``, ``MockThreadPersistenceStore``, ``MockAgentTemplateStore``,
/// ``MockWorkspacePersistence``, ``MockToolPersistence``) so a test can construct a single
/// object instead of wiring up every store protocol separately.
///
/// Configurable: `mockHealthStatus`/`mockHealthDetails`; `saveOriginMock`/`fetchOriginMock`/
/// `fetchAllOriginsMock`/`deleteOriginMock` (closures overriding `RequestOriginStoreProtocol`
/// behavior — unset closures make origin operations no-ops/return empty). Inspectable:
/// `messages`, `threads`, `agentTemplates`, `workspaces`,
/// `agents` all forward to the underlying focused mocks. `resetDatabase()` clears
/// every backing store.
///
/// Health, durability, request-origin callbacks, and agents share one mutex state.
/// Agent insert-or-replace and each tool-workspace mirror upsert are atomic; the two backing stores
/// are not a cross-store transaction. Callback values are snapshotted while locked, then invoked
/// after unlocking, so no mutex crosses an `await` or caller-provided code.
public final class MockPersistenceService: ThreadRuntimeRepository, WorkspaceStore, AgentTemplateStoreProtocol, RequestOriginStoreProtocol, ToolPersistenceProtocol, AgentStoreProtocol, HealthCheckable {
    private struct State: Sendable {
        var mockHealthStatus: HealthStatus = .ok
        var mockHealthDetails: [String: String]? = ["mock": "true"]
        var mockIsDurable = false
        var fetchThreadFails = false
        var completeTurnFails = false
        var deletedMessageThreadIDs: Set<UUID> = []
        var saveMessageFailureAfter: Int?
        var saveMessageCallCount = 0
        var recordToolResultFailureAfter: Int?
        var recordToolResultCallCount = 0
        var accessCount = 0
        var saveOriginMock: (@Sendable (RequestOriginIdentity) async throws -> Void)?
        var fetchOriginMock: (@Sendable (UUID) async throws -> RequestOriginIdentity?)?
        var fetchAllOriginsMock: (@Sendable () async throws -> [RequestOriginIdentity])?
        var deleteOriginMock: (@Sendable (UUID) async throws -> Bool)?
        var agents: [Agent] = []
    }

    private let messagesMock = MockMessageStore()
    private let threadsMock = MockThreadPersistenceStore()
    private let agentTemplatesMock = MockAgentTemplateStore()
    private let workspacesMock = MockWorkspacePersistence()
    private let toolsMock = MockToolPersistence()
    private let turnRuntime = InMemoryThreadRuntimeRepository()
    private let state = Mutex(State())

    public var mockHealthStatus: HealthStatus {
        get { state.withLock { $0.mockHealthStatus } }
        set { state.withLock { $0.mockHealthStatus = newValue } }
    }

    public var mockHealthDetails: [String: String]? {
        get { state.withLock { $0.mockHealthDetails } }
        set { state.withLock { $0.mockHealthDetails = newValue } }
    }

    /// Overrides `isDurable` for all seven store protocol conformances.
    /// Defaults to `false` (matching the protocol default); set to `true` to simulate a
    /// durable (GRDB/SwiftData-backed) store in durability tests.
    public var mockIsDurable: Bool {
        get { state.withLock { $0.mockIsDurable } }
        set { state.withLock { $0.mockIsDurable = newValue } }
    }

    public var isDurable: Bool { state.withLock { $0.mockIsDurable } }

    /// When enabled, thread reads fail with the shared failure-test error so callers can verify
    /// unavailable persistence behavior through the cohesive runtime repository.
    public var fetchThreadFails: Bool {
        get { state.withLock { $0.fetchThreadFails } }
        set { state.withLock { $0.fetchThreadFails = newValue } }
    }

    /// Causes terminal outcome persistence to fail, after the Turn has been admitted.
    public var completeTurnFails: Bool {
        get { state.withLock { $0.completeTurnFails } }
        set { state.withLock { $0.completeTurnFails = newValue } }
    }

    /// Causes message persistence to fail after the specified number of successful calls. This
    /// exercises retry behavior without splitting the runtime repository into independent stores.
    public var saveMessageFailureAfter: Int? {
        get { state.withLock { $0.saveMessageFailureAfter } }
        set { state.withLock { $0.saveMessageFailureAfter = newValue; $0.saveMessageCallCount = 0 } }
    }

    /// Causes the cohesive tool-result transition to fail after the specified number of
    /// successful calls, keeping failure injection behind the runtime repository boundary.
    public var recordToolResultFailureAfter: Int? {
        get { state.withLock { $0.recordToolResultFailureAfter } }
        set { state.withLock { $0.recordToolResultFailureAfter = newValue; $0.recordToolResultCallCount = 0 } }
    }

    // Mocks
    public var saveOriginMock: (@Sendable (RequestOriginIdentity) async throws -> Void)? {
        get { state.withLock { $0.saveOriginMock } }
        set { state.withLock { $0.saveOriginMock = newValue } }
    }

    public var fetchOriginMock: (@Sendable (UUID) async throws -> RequestOriginIdentity?)? {
        get { state.withLock { $0.fetchOriginMock } }
        set { state.withLock { $0.fetchOriginMock = newValue } }
    }

    public var fetchAllOriginsMock: (@Sendable () async throws -> [RequestOriginIdentity])? {
        get { state.withLock { $0.fetchAllOriginsMock } }
        set { state.withLock { $0.fetchAllOriginsMock = newValue } }
    }

    public var deleteOriginMock: (@Sendable (UUID) async throws -> Bool)? {
        get { state.withLock { $0.deleteOriginMock } }
        set { state.withLock { $0.deleteOriginMock = newValue } }
    }

    public init() {}

    /// Package-only inspection for runtime preflight tests. The counter records protocol method
    /// calls without changing the public mock surface or its stored-value inspection properties.
    package var persistenceAccessCount: Int {
        state.withLock { $0.accessCount }
    }

    private func recordPersistenceAccess() {
        state.withLock { $0.accessCount += 1 }
    }

    public func getHealthDetails() async -> [String: String]? {
        defer { recordPersistenceAccess() }
        return state.withLock { $0.mockHealthDetails }
    }

    public func checkHealth() async -> HealthStatus {
        defer { recordPersistenceAccess() }
        return state.withLock { $0.mockHealthStatus }
    }

    // MARK: - ThreadMessageStoreProtocol

    public var messages: [ThreadMessage] {
        get { messagesMock.messages }
        set { messagesMock.messages = newValue }
    }

    public func saveMessage(_ message: ThreadMessage) async throws {
        defer { recordPersistenceAccess() }
        let shouldFail = state.withLock { state in
            state.saveMessageCallCount += 1
            guard let limit = state.saveMessageFailureAfter else { return false }
            return state.saveMessageCallCount > limit
        }
        if shouldFail { throw FailingStoreError.saveFailed }
        try await messagesMock.saveMessage(message)
        try await turnRuntime.saveMessage(message)
        _ = state.withLock { $0.deletedMessageThreadIDs.remove(message.threadID) }
    }

    public func fetchMessages(for threadID: UUID) async throws -> [ThreadMessage] {
        defer { recordPersistenceAccess() }
        let focused = try await messagesMock.fetchMessages(for: threadID)
        let cohesive: [ThreadMessage]
        if state.withLock({ $0.deletedMessageThreadIDs.contains(threadID) }) {
            cohesive = []
        } else {
            cohesive = try await turnRuntime.fetchMessages(for: threadID)
        }
        var merged = focused
        let existingIDs = Set(focused.map(\.id))
        merged.append(contentsOf: cohesive.filter { !existingIDs.contains($0.id) })
        return merged.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.timestamp < rhs.timestamp
        }
    }

    public func deleteMessages(for threadID: UUID) async throws {
        defer { recordPersistenceAccess() }
        throw ThreadRuntimeRepositoryError.historyDeletionForbidden(threadID: threadID)
    }

    public func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        defer { recordPersistenceAccess() }
        return try await messagesMock.pruneMessages(olderThan: timeInterval, dryRun: dryRun)
    }

    public func fetchSnapshots(for threadID: UUID) async throws -> [TurnSnapshot] {
        defer { recordPersistenceAccess() }
        return try await messagesMock.fetchSnapshots(for: threadID)
    }

    // MARK: - ThreadPersistenceProtocol

    public var threads: [Thread] {
        get { threadsMock.threads }
        set { threadsMock.threads = newValue }
    }

    public func saveThread(_ thread: Thread) async throws {
        defer { recordPersistenceAccess() }
        try await threadsMock.saveThread(thread)
        try await turnRuntime.saveThread(thread)
    }

    public func fetchThread(id: UUID) async throws -> Thread? {
        defer { recordPersistenceAccess() }
        if fetchThreadFails { throw FailingStoreError.fetchFailed }
        return try await threadsMock.fetchThread(id: id)
    }

    public func fetchAllThreads(includeArchived: Bool) async throws -> [Thread] {
        defer { recordPersistenceAccess() }
        return try await threadsMock.fetchAllThreads(includeArchived: includeArchived)
    }

    public func deleteThread(id: UUID) async throws {
        defer { recordPersistenceAccess() }
        // `ThreadRuntimeRepository.deleteThread(id:)` must cascade history deletion (see the
        // protocol's doc comment). This mock backs message reads with two stores — a focused
        // `messagesMock` and the cohesive `turnRuntime` — so both must drop the thread's
        // messages here for `fetchMessages(for:)` to reflect the same cascade a real conformer
        // guarantees.
        try await messagesMock.deleteMessages(for: id)
        _ = state.withLock { $0.deletedMessageThreadIDs.insert(id) }
        try await threadsMock.deleteThread(id: id)
        try await turnRuntime.deleteThread(id: id)
    }

    public func pruneThreads(olderThan timeInterval: TimeInterval, excluding excludedThreadIDs: [UUID], dryRun: Bool) async throws -> Int {
        defer { recordPersistenceAccess() }
        return try await threadsMock.pruneThreads(olderThan: timeInterval, excluding: excludedThreadIDs, dryRun: dryRun)
    }

    // MARK: - AgentTemplateStoreProtocol

    public var agentTemplates: [AgentTemplate] {
        get { agentTemplatesMock.agentTemplates }
        set { agentTemplatesMock.agentTemplates = newValue }
    }

    public func saveAgentTemplate(_ agent: AgentTemplate) async throws {
        defer { recordPersistenceAccess() }
        try await agentTemplatesMock.saveAgentTemplate(agent)
    }

    public func fetchAgentTemplate(id: UUID) async throws -> AgentTemplate? {
        defer { recordPersistenceAccess() }
        return try await agentTemplatesMock.fetchAgentTemplate(id: id)
    }

    public func fetchAgentTemplate(key: String) async throws -> AgentTemplate? {
        defer { recordPersistenceAccess() }
        return try await agentTemplatesMock.fetchAgentTemplate(key: key)
    }

    public func fetchAllAgentTemplates() async throws -> [AgentTemplate] {
        defer { recordPersistenceAccess() }
        return try await agentTemplatesMock.fetchAllAgentTemplates()
    }

    public func hasAgentTemplate(id: String) async -> Bool {
        defer { recordPersistenceAccess() }
        return await agentTemplatesMock.hasAgentTemplate(id: id)
    }

    // MARK: - WorkspaceStore

    public var workspaces: [WorkspaceReference] {
        get { workspacesMock.workspaces }
        set {
            workspacesMock.workspaces = newValue
            toolsMock.workspaces = newValue
        }
    }

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        defer { recordPersistenceAccess() }
        try await workspacesMock.saveWorkspace(workspace)
        toolsMock.upsertWorkspace(workspace)
    }

    public func fetchWorkspace(id: UUID, includeTools: Bool = false) async throws -> WorkspaceReference? {
        defer { recordPersistenceAccess() }
        var ws = try await workspacesMock.fetchWorkspace(id: id, includeTools: includeTools)
        if includeTools, ws != nil {
            if let toolsWs = toolsMock.workspaces.first(where: { $0.id == id }) {
                ws?.tools = toolsWs.tools
            }
        }
        return ws
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        defer { recordPersistenceAccess() }
        return try await workspacesMock.fetchAllWorkspaces()
    }

    public func deleteWorkspace(id: UUID) async throws {
        defer { recordPersistenceAccess() }
        try await workspacesMock.deleteWorkspace(id: id)
    }

    // MARK: - ToolPersistenceProtocol

    public func addToolToWorkspace(workspaceId: UUID, tool: ToolReference) async throws {
        defer { recordPersistenceAccess() }
        try await toolsMock.addToolToWorkspace(workspaceId: workspaceId, tool: tool)
    }

    public func syncTools(workspaceId: UUID, tools: [ToolReference]) async throws {
        defer { recordPersistenceAccess() }
        try await toolsMock.syncTools(workspaceId: workspaceId, tools: tools)
    }

    public func fetchTools(forWorkspaces workspaceIds: [UUID]) async throws -> [ToolReference] {
        defer { recordPersistenceAccess() }
        return try await toolsMock.fetchTools(forWorkspaces: workspaceIds)
    }

    public func fetchOriginTools(originId: UUID) async throws -> [ToolReference] {
        defer { recordPersistenceAccess() }
        return try await toolsMock.fetchOriginTools(originId: originId)
    }

    public func findWorkspaceId(forToolId toolId: String, in workspaceIds: [UUID]) async throws -> UUID? {
        defer { recordPersistenceAccess() }
        return try await toolsMock.findWorkspaceId(forToolId: toolId, in: workspaceIds)
    }

    public func fetchToolSource(toolId: String, workspaceIds: [UUID], primaryWorkspaceId: UUID?) async throws -> String? {
        defer { recordPersistenceAccess() }
        return try await toolsMock.fetchToolSource(toolId: toolId, workspaceIds: workspaceIds, primaryWorkspaceId: primaryWorkspaceId)
    }

    // MARK: - RequestOriginStoreProtocol

    public func saveOrigin(_ origin: RequestOriginIdentity) async throws {
        defer { recordPersistenceAccess() }
        let mock = state.withLock { $0.saveOriginMock }
        if let mock { try await mock(origin) }
    }

    public func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity? {
        defer { recordPersistenceAccess() }
        let mock = state.withLock { $0.fetchOriginMock }
        if let mock { return try await mock(id) }
        return nil
    }

    public func fetchAllOrigins() async throws -> [RequestOriginIdentity] {
        defer { recordPersistenceAccess() }
        let mock = state.withLock { $0.fetchAllOriginsMock }
        if let mock { return try await mock() }
        return []
    }

    public func deleteOrigin(id: UUID) async throws -> Bool {
        defer { recordPersistenceAccess() }
        let mock = state.withLock { $0.deleteOriginMock }
        if let mock {
            return try await mock(id)
        }
        return false
    }

    // MARK: - AgentStoreProtocol

    public var agents: [Agent] {
        get { state.withLock { $0.agents } }
        set { state.withLock { $0.agents = newValue } }
    }

    public func saveAgent(_ instance: Agent) async throws {
        defer { recordPersistenceAccess() }
        state.withLock {
            if let index = $0.agents.firstIndex(where: { $0.id == instance.id }) {
                $0.agents[index] = instance
            } else {
                $0.agents.append(instance)
            }
        }
    }

    public func fetchAgent(id: UUID) async throws -> Agent? {
        defer { recordPersistenceAccess() }
        return state.withLock { $0.agents.first { $0.id == id } }
    }

    public func fetchAllAgents() async throws -> [Agent] {
        defer { recordPersistenceAccess() }
        return state.withLock { $0.agents }
    }

    public func deleteAgent(id: UUID) async throws {
        defer { recordPersistenceAccess() }
        state.withLock { $0.agents.removeAll { $0.id == id } }
    }

    public func fetchThreads(attachedToAgent agentId: UUID) async throws -> [Thread] {
        defer { recordPersistenceAccess() }
        return threads.filter { $0.attachedAgentID == agentId }
    }

    public func resetDatabase() async throws {
        defer { recordPersistenceAccess() }
        messages = []
        threads = []
        agentTemplates = []
        workspaces = []
        state.withLock {
            $0.agents = []
            $0.deletedMessageThreadIDs = []
        }
        toolsMock.workspaces = []
    }
}

// MARK: - TurnRuntimeRepository forwarding

extension MockPersistenceService {
    public func admitTurn(threadID: UUID, requestID: UUID, callerIntentFingerprint: String,
                          inputMessage: ThreadMessage?, executionKind: TurnExecutionKind,
                          capturedAgentID: UUID?, turnID: UUID, now: Date) async throws -> TurnAdmission {
        defer { recordPersistenceAccess() }
        return try await turnRuntime.admitTurn(threadID: threadID, requestID: requestID,
                                        callerIntentFingerprint: callerIntentFingerprint,
                                        inputMessage: inputMessage, executionKind: executionKind,
                                        capturedAgentID: capturedAgentID, turnID: turnID, now: now)
    }

    public func admitRetry(threadID: UUID, previousTurnID: UUID, requestID: UUID,
                           callerIntentFingerprint: String, inputMessage: ThreadMessage?,
                           executionKind: TurnExecutionKind, capturedAgentID: UUID?, turnID: UUID,
                           attempt: Int, now: Date) async throws -> TurnAdmission {
        defer { recordPersistenceAccess() }
        return try await turnRuntime.admitRetry(threadID: threadID, previousTurnID: previousTurnID,
                                         requestID: requestID, callerIntentFingerprint: callerIntentFingerprint,
                                         inputMessage: inputMessage, executionKind: executionKind,
                                         capturedAgentID: capturedAgentID, turnID: turnID, attempt: attempt, now: now)
    }

    public func fetchTurn(id: UUID) async throws -> TurnRecord? { recordPersistenceAccess(); return try await turnRuntime.fetchTurn(id: id) }
    public func fetchActiveTurn(for threadID: UUID) async throws -> TurnRecord? { recordPersistenceAccess(); return try await turnRuntime.fetchActiveTurn(for: threadID) }
    public func appendNotice(turnID: UUID, notice: TurnNotice) async throws { recordPersistenceAccess(); try await turnRuntime.appendNotice(turnID: turnID, notice: notice) }
    public func appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date) async throws { recordPersistenceAccess(); try await turnRuntime.appendCorrelation(turnID: turnID, correlation: correlation, now: now) }
    public func fetchNotices(turnID: UUID) async throws -> [TurnNotice] { recordPersistenceAccess(); return try await turnRuntime.fetchNotices(turnID: turnID) }
    public func fetchCorrelations(turnID: UUID) async throws -> [TurnCorrelation] { recordPersistenceAccess(); return try await turnRuntime.fetchCorrelations(turnID: turnID) }
    public func beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date) async throws { recordPersistenceAccess(); try await turnRuntime.beginModelRound(turnID: turnID, modelRoundIndex: modelRoundIndex, now: now) }
    public func recordProviderRequest(turnID: UUID, modelRoundIndex: Int, correlation: TurnCorrelation?, now: Date) async throws { recordPersistenceAccess(); try await turnRuntime.recordProviderRequest(turnID: turnID, modelRoundIndex: modelRoundIndex, correlation: correlation, now: now) }
    public func recordToolIntent(_ intent: RuntimeToolIntent) async throws { recordPersistenceAccess(); try await turnRuntime.recordToolIntent(intent) }
    public func recordToolResult(_ result: RuntimeToolResult) async throws { recordPersistenceAccess(); try await turnRuntime.recordToolResult(result) }
    public func recordToolResult(_ result: RuntimeToolResult, message: ThreadMessage) async throws {
        defer { recordPersistenceAccess() }
        let shouldFail = state.withLock { state in
            state.recordToolResultCallCount += 1
            guard let limit = state.recordToolResultFailureAfter else { return false }
            return state.recordToolResultCallCount > limit
        }
        if shouldFail { throw FailingStoreError.saveFailed }
        try await turnRuntime.recordToolResult(result, message: message)
    }
    public func fetchToolIntents(turnID: UUID) async throws -> [RuntimeToolIntent] { recordPersistenceAccess(); return try await turnRuntime.fetchToolIntents(turnID: turnID) }
    public func fetchToolResults(turnID: UUID) async throws -> [RuntimeToolResult] { recordPersistenceAccess(); return try await turnRuntime.fetchToolResults(turnID: turnID) }
    public func completeTurn(turnID: UUID, outcome: TurnOutcome, finalMessage: ThreadMessage?, terminalHandle: TurnTerminalHandle?, now: Date) async throws -> TurnRecord {
        defer { recordPersistenceAccess() }
        if state.withLock({ $0.completeTurnFails }) {
            throw FailingStoreError.saveFailed
        }
        let record = try await turnRuntime.completeTurn(
            turnID: turnID,
            outcome: outcome,
            finalMessage: finalMessage,
            terminalHandle: terminalHandle,
            now: now
        )
        // Keep the inspectable focused projection aligned with the cohesive runtime owner. The
        // test double intentionally exposes both protocol seams, so direct `messages` assertions
        // should observe terminal assistant rows committed through `completeTurn` as well.
        if let finalMessage {
            try await messagesMock.saveMessage(finalMessage)
        }
        return record
    }
    public func failTurn(turnID: UUID, message: String, now: Date) async throws -> TurnRecord { recordPersistenceAccess(); return try await turnRuntime.failTurn(turnID: turnID, message: message, now: now) }
    public func cancelTurn(turnID: UUID, reason: String?, now: Date) async throws -> TurnRecord { recordPersistenceAccess(); return try await turnRuntime.cancelTurn(turnID: turnID, reason: reason, now: now) }
    public func interruptTurn(turnID: UUID, reason: String, force: Bool, now: Date) async throws -> TurnRecord { recordPersistenceAccess(); return try await turnRuntime.interruptTurn(turnID: turnID, reason: reason, force: force, now: now) }
    public func recover(threadID: UUID, now: Date) async throws -> TurnRecoveryResult { recordPersistenceAccess(); return try await turnRuntime.recover(threadID: threadID, now: now) }
    public func forceClear(threadID: UUID, confirmation: ForceClearConfirmation, now: Date) async throws -> TurnRecord? { recordPersistenceAccess(); return try await turnRuntime.forceClear(threadID: threadID, confirmation: confirmation, now: now) }
    public func saveSummary(_ summary: ThreadSummary) async throws { recordPersistenceAccess(); try await turnRuntime.saveSummary(summary) }
    public func fetchSummaries(for threadID: UUID) async throws -> [ThreadSummary] { recordPersistenceAccess(); return try await turnRuntime.fetchSummaries(for: threadID) }
}
