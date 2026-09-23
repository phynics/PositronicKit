import Foundation
import PKContracts
import PKUtilities
import PositronicKit
import Synchronization

/// Composite in-memory test double for the full persistence surface (messages,
/// timelines, agent templates, workspaces, request origins, agents,
/// health), delegating each protocol area to its own focused mock,
/// ``MockMessageStore``, ``MockTimelinePersistenceStore``, ``MockAgentTemplateStore``,
/// ``MockWorkspacePersistence``) so a test can construct a single
/// object instead of wiring up every store protocol separately.
///
/// Configurable: `mockHealthStatus`/`mockHealthDetails`; `saveOriginMock`/`fetchOriginMock`/
/// `fetchAllOriginsMock`/`deleteOriginMock` (closures overriding `RequestOriginStoreProtocol`
/// behavior — unset closures make origin operations no-ops/return empty). Inspectable:
/// `messages`, `timelines`, `agentTemplates`, `workspaces`,
/// `agents` all forward to the underlying focused mocks. `resetDatabase()` clears
/// every backing store.
///
/// Health, durability, request-origin callbacks, and agents share one mutex state.
/// Agent insert-or-replace is atomic. Callback values are snapshotted while locked, then invoked
/// after unlocking, so no mutex crosses an `await` or caller-provided code.
public final class MockPersistenceService: TimelineRuntimeRepository, TimelineSummaryStore, WorkspaceStore, AgentTemplateStoreProtocol, RequestOriginStoreProtocol, AgentStoreProtocol, HealthCheckable {
    private struct State: Sendable {
        var mockHealthStatus: HealthStatus = .ok
        var mockHealthDetails: [String: String]? = ["mock": "true"]
        var mockIsDurable = false
        var fetchTimelineFails = false
        var completeTurnFails = false
        var completeTurnBlocker: (@Sendable () async -> Void)?
        var completeTurnChecksCancellation = false
        var unorderedMessagesForTimelineID: UUID?
        var deletedMessageTimelineIDs: Set<UUID> = []
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
    private let timelinesMock = MockTimelinePersistenceStore()
    private let agentTemplatesMock = MockAgentTemplateStore()
    private let workspacesMock = MockWorkspacePersistence()
    private let turnRuntime = InMemoryTimelineRuntimeRepository()
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

    /// When enabled, timeline reads fail with the shared failure-test error so callers can verify
    /// unavailable persistence behavior through the cohesive runtime repository.
    public var fetchTimelineFails: Bool {
        get { state.withLock { $0.fetchTimelineFails } }
        set { state.withLock { $0.fetchTimelineFails = newValue } }
    }

    /// Causes terminal outcome persistence to fail, after the Turn has been admitted.
    public var completeTurnFails: Bool {
        get { state.withLock { $0.completeTurnFails } }
        set { state.withLock { $0.completeTurnFails = newValue } }
    }

    /// Parks a terminal commit until the test releases it. `completeTurn` awaits the closure before
    /// committing, so a test can hold a commit open and prove Timeline eviction is not blocked by a
    /// hung host store (ADR 0010).
    public var completeTurnBlocker: (@Sendable () async -> Void)? {
        get { state.withLock { $0.completeTurnBlocker } }
        set { state.withLock { $0.completeTurnBlocker = newValue } }
    }

    /// When enabled, `completeTurn` throws `CancellationError` if the executing task is cancelled.
    /// The terminal commit runs in the runtime-owned finalizer, which is never the cancelled Turn
    /// task, so a cancellation-aware store must still commit (ADR 0010, #195).
    public var completeTurnChecksCancellation: Bool {
        get { state.withLock { $0.completeTurnChecksCancellation } }
        set { state.withLock { $0.completeTurnChecksCancellation = newValue } }
    }

    /// Package-only test control that reverses fetched messages for one fixture Timeline to prove
    /// the shipped conformance suite detects an adapter that violates the ordering contract.
    package var unorderedMessagesForTimelineID: UUID? {
        get { state.withLock { $0.unorderedMessagesForTimelineID } }
        set { state.withLock { $0.unorderedMessagesForTimelineID = newValue } }
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

    public var healthDetails: [String: String]? {
        get async {
            defer { recordPersistenceAccess() }
            return state.withLock { $0.mockHealthDetails }
        }
    }

    public func checkHealth() async -> HealthStatus {
        defer { recordPersistenceAccess() }
        return state.withLock { $0.mockHealthStatus }
    }

    // MARK: - TimelineMessageStoreProtocol

    public var messages: [TimelineMessage] {
        get { messagesMock.messages }
        set { messagesMock.messages = newValue }
    }

    public func saveMessage(_ message: TimelineMessage) async throws {
        defer { recordPersistenceAccess() }
        let shouldFail = state.withLock { state in
            state.saveMessageCallCount += 1
            guard let limit = state.saveMessageFailureAfter else { return false }
            return state.saveMessageCallCount > limit
        }
        if shouldFail { throw FailingStoreError.saveFailed }
        try await messagesMock.saveMessage(message)
        try await turnRuntime.saveMessage(message)
        _ = state.withLock { $0.deletedMessageTimelineIDs.remove(message.timelineID) }
    }

    public func fetchMessages(for timelineID: UUID) async throws -> [TimelineMessage] {
        defer { recordPersistenceAccess() }
        let focused = try await messagesMock.fetchMessages(for: timelineID)
        let cohesive: [TimelineMessage]
        if state.withLock({ $0.deletedMessageTimelineIDs.contains(timelineID) }) {
            cohesive = []
        } else {
            cohesive = try await turnRuntime.fetchMessages(for: timelineID)
        }
        var merged = focused
        let existingIDs = Set(focused.map(\.id))
        merged.append(contentsOf: cohesive.filter { !existingIDs.contains($0.id) })
        if state.withLock({ $0.unorderedMessagesForTimelineID == timelineID }) {
            return Array(merged.reversed())
        }
        return merged
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.timestamp != rhs.element.timestamp {
                    return lhs.element.timestamp < rhs.element.timestamp
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    public func deleteMessages(for timelineID: UUID) async throws {
        defer { recordPersistenceAccess() }
        throw TimelineRuntimeRepositoryError.historyDeletionForbidden(timelineID: timelineID)
    }

    public func pruneMessages(olderThan timeInterval: TimeInterval, dryRun: Bool) async throws -> Int {
        defer { recordPersistenceAccess() }
        return try await messagesMock.pruneMessages(olderThan: timeInterval, dryRun: dryRun)
    }

    public func fetchSnapshots(for timelineID: UUID) async throws -> [TurnSnapshot] {
        defer { recordPersistenceAccess() }
        return try await messagesMock.fetchSnapshots(for: timelineID)
    }

    // MARK: - TimelinePersistenceProtocol

    public var timelines: [TimelineRecord] {
        get { timelinesMock.timelines }
        set { timelinesMock.timelines = newValue }
    }

    public func saveTimeline(_ timeline: TimelineRecord) async throws {
        defer { recordPersistenceAccess() }
        try await timelinesMock.saveTimeline(timeline)
        try await turnRuntime.saveTimeline(timeline)
    }

    public func fetchTimeline(id: UUID) async throws -> TimelineRecord? {
        defer { recordPersistenceAccess() }
        if fetchTimelineFails { throw FailingStoreError.fetchFailed }
        return try await timelinesMock.fetchTimeline(id: id)
    }

    public func fetchAllTimelines(includeArchived: Bool) async throws -> [TimelineRecord] {
        defer { recordPersistenceAccess() }
        return try await timelinesMock.fetchAllTimelines(includeArchived: includeArchived)
    }

    public func deleteTimeline(id: UUID) async throws {
        defer { recordPersistenceAccess() }
        // `TimelineRuntimeRepository.deleteTimeline(id:)` must cascade history deletion (see the
        // protocol's doc comment). This mock backs message reads with two stores — a focused
        // `messagesMock` and the cohesive `turnRuntime` — so both must drop the timeline's
        // messages here for `fetchMessages(for:)` to reflect the same cascade a real conformer
        // guarantees.
        try await messagesMock.deleteMessages(for: id)
        _ = state.withLock { $0.deletedMessageTimelineIDs.insert(id) }
        try await timelinesMock.deleteTimeline(id: id)
        try await turnRuntime.deleteTimeline(id: id)
    }

    public func pruneTimelines(olderThan timeInterval: TimeInterval, excluding excludedTimelineIDs: [UUID], dryRun: Bool) async throws -> Int {
        defer { recordPersistenceAccess() }
        return try await timelinesMock.pruneTimelines(olderThan: timeInterval, excluding: excludedTimelineIDs, dryRun: dryRun)
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
        set { workspacesMock.workspaces = newValue }
    }

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        defer { recordPersistenceAccess() }
        try await workspacesMock.saveWorkspace(workspace)
    }

    public func fetchWorkspace(id: UUID, includeTools: Bool = false) async throws -> WorkspaceReference? {
        defer { recordPersistenceAccess() }
        return try await workspacesMock.fetchWorkspace(id: id, includeTools: includeTools)
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        defer { recordPersistenceAccess() }
        return try await workspacesMock.fetchAllWorkspaces()
    }

    public func deleteWorkspace(id: UUID) async throws {
        defer { recordPersistenceAccess() }
        try await workspacesMock.deleteWorkspace(id: id)
    }

    /// Test seeding: appends `tool` to a saved workspace's tool list, as a host provider reports
    /// a newly available tool. Throws `ToolError.workspaceNotFound` for an unsaved workspace.
    public func addToolToWorkspace(workspaceID: UUID, tool: ToolReference) async throws {
        defer { recordPersistenceAccess() }
        try workspacesMock.appendTool(tool, toWorkspace: workspaceID)
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

    public func fetchTimelines(attachedToAgent agentID: UUID) async throws -> [TimelineRecord] {
        defer { recordPersistenceAccess() }
        return timelines.filter { $0.attachedAgentID == agentID }
    }

    public func resetDatabase() async throws {
        defer { recordPersistenceAccess() }
        messages = []
        timelines = []
        agentTemplates = []
        workspaces = []
        state.withLock {
            $0.agents = []
            $0.deletedMessageTimelineIDs = []
        }
    }
}

// MARK: - TurnRuntimeRepository forwarding

extension MockPersistenceService {
    public func admitTurn(timelineID: UUID, requestID: UUID, callerIntentFingerprint: String,
                          inputMessage: TimelineMessage?, executionKind: TurnExecutionKind,
                          capturedAgentID: UUID?, turnID: UUID, now: Date) async throws -> TurnAdmission {
        defer { recordPersistenceAccess() }
        return try await turnRuntime.admitTurn(timelineID: timelineID, requestID: requestID,
                                        callerIntentFingerprint: callerIntentFingerprint,
                                        inputMessage: inputMessage, executionKind: executionKind,
                                        capturedAgentID: capturedAgentID, turnID: turnID, now: now)
    }

    public func admitRetry(timelineID: UUID, previousTurnID: UUID, requestID: UUID,
                           callerIntentFingerprint: String, inputMessage: TimelineMessage?,
                           executionKind: TurnExecutionKind, capturedAgentID: UUID?, turnID: UUID,
                           attempt: Int, now: Date) async throws -> TurnAdmission {
        defer { recordPersistenceAccess() }
        return try await turnRuntime.admitRetry(timelineID: timelineID, previousTurnID: previousTurnID,
                                         requestID: requestID, callerIntentFingerprint: callerIntentFingerprint,
                                         inputMessage: inputMessage, executionKind: executionKind,
                                         capturedAgentID: capturedAgentID, turnID: turnID, attempt: attempt, now: now)
    }

    public func fetchTurn(id: UUID) async throws -> TurnRecord? { recordPersistenceAccess(); return try await turnRuntime.fetchTurn(id: id) }
    public func fetchActiveTurn(for timelineID: UUID) async throws -> TurnRecord? { recordPersistenceAccess(); return try await turnRuntime.fetchActiveTurn(for: timelineID) }
    public func appendNotice(turnID: UUID, notice: TurnNotice) async throws { recordPersistenceAccess(); try await turnRuntime.appendNotice(turnID: turnID, notice: notice) }
    public func appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date) async throws { recordPersistenceAccess(); try await turnRuntime.appendCorrelation(turnID: turnID, correlation: correlation, now: now) }
    public func fetchNotices(turnID: UUID) async throws -> [TurnNotice] { recordPersistenceAccess(); return try await turnRuntime.fetchNotices(turnID: turnID) }
    public func fetchCorrelations(turnID: UUID) async throws -> [TurnCorrelation] { recordPersistenceAccess(); return try await turnRuntime.fetchCorrelations(turnID: turnID) }
    public func beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date) async throws { recordPersistenceAccess(); try await turnRuntime.beginModelRound(turnID: turnID, modelRoundIndex: modelRoundIndex, now: now) }
    public func recordProviderRequest(turnID: UUID, modelRoundIndex: Int, correlation: TurnCorrelation?, now: Date) async throws { recordPersistenceAccess(); try await turnRuntime.recordProviderRequest(turnID: turnID, modelRoundIndex: modelRoundIndex, correlation: correlation, now: now) }
    public func recordToolIntent(_ intent: RuntimeToolIntent) async throws { recordPersistenceAccess(); try await turnRuntime.recordToolIntent(intent) }
    public func recordToolResult(_ result: RuntimeToolResult) async throws { recordPersistenceAccess(); try await turnRuntime.recordToolResult(result) }
    public func recordToolResult(_ result: RuntimeToolResult, message: TimelineMessage) async throws {
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
    public func completeTurn(turnID: UUID, outcome: TurnOutcome, finalMessage: TimelineMessage?, terminalHandle: TurnTerminalHandle?, now: Date) async throws -> TurnRecord {
        defer { recordPersistenceAccess() }
        // The injection targets the terminal completion path only. A failed/cancelled/interrupted
        // outcome still commits, so `failTurn`/`cancelTurn` convenience paths and the retry
        // linkage scenario keep working while the completion scenario observes the failure.
        if case .completed = outcome, state.withLock({ $0.completeTurnFails }) {
            throw FailingStoreError.saveFailed
        }
        if state.withLock({ $0.completeTurnChecksCancellation }), Task.isCancelled {
            throw CancellationError()
        }
        if let blocker = state.withLock({ $0.completeTurnBlocker }) {
            await blocker()
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
    public func interruptTurn(turnID: UUID, reason: String, disposition: TurnInterruptDisposition, now: Date) async throws -> TurnInterruptResult { recordPersistenceAccess(); return try await turnRuntime.interruptTurn(turnID: turnID, reason: reason, disposition: disposition, now: now) }
    public func releaseQuarantine(timelineID: UUID, turnID: UUID, confirmation: QuarantineReleaseConfirmation, now: Date) async throws -> TurnRecord { recordPersistenceAccess(); return try await turnRuntime.releaseQuarantine(timelineID: timelineID, turnID: turnID, confirmation: confirmation, now: now) }
    public func saveSummary(_ summary: TimelineSummary) async throws { recordPersistenceAccess(); try await turnRuntime.saveSummary(summary) }
    public func fetchSummaries(for timelineID: UUID) async throws -> [TimelineSummary] { recordPersistenceAccess(); return try await turnRuntime.fetchSummaries(for: timelineID) }
}
