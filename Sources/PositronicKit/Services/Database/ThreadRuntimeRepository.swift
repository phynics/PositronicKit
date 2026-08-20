import Foundation
import PKContracts
import PKUtilities

// MARK: - Turn durability vocabulary

/// The caller-owned identity used to make turn admission idempotent.
///
/// A fingerprint is deliberately opaque to the repository. The caller computes it from the
/// complete intent that it considers retry-equivalent; the repository only compares it byte for
/// byte when a Request ID is presented again.
public struct TurnCallerIntent: Codable, Hashable, Sendable {
    public let requestID: UUID
    public let fingerprint: String

    public init(requestID: UUID, fingerprint: String) {
        self.requestID = requestID
        self.fingerprint = fingerprint
    }
}

/// Durable lifecycle states for a Turn.
public enum TurnLifecycle: String, Codable, Hashable, Sendable {
    case admitted
    case running
    case awaitingTool
    case completed
    case failed
    case cancelled
    case interrupted
}

/// The terminal truth recorded by the runtime repository.
public enum TurnOutcome: Codable, Equatable, Sendable {
    case completed
    case failed(message: String)
    case cancelled(reason: String?)
    case interrupted(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, message, reason
    }

    private enum Kind: String, Codable {
        case completed, failed, cancelled, interrupted
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed:
            try container.encode(Kind.completed, forKey: .kind)
        case let .failed(message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(message, forKey: .message)
        case let .cancelled(reason):
            try container.encode(Kind.cancelled, forKey: .kind)
            try container.encodeIfPresent(reason, forKey: .reason)
        case let .interrupted(reason):
            try container.encode(Kind.interrupted, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .completed:
            self = .completed
        case .failed:
            self = .failed(message: try container.decode(String.self, forKey: .message))
        case .cancelled:
            self = .cancelled(reason: try container.decodeIfPresent(String.self, forKey: .reason))
        case .interrupted:
            self = .interrupted(reason: try container.decode(String.self, forKey: .reason))
        }
    }
}

/// Why a durable record is present in a Turn's audit trail.
public struct TurnNotice: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let kind: String
    public let message: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: String, message: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
    }
}

/// A provider/tool correlation retained with a Turn, without making provider identity part of the
/// core contract.
public struct TurnCorrelation: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let kind: String
    public let value: String

    public init(id: UUID = UUID(), kind: String, value: String) {
        self.id = id
        self.kind = kind
        self.value = value
    }
}

/// Links a retry to the durable Turn it supersedes. A retry is a relation, not a new history
/// branch, so the original record is never deleted or rewritten.
public struct TurnRetryRelation: Codable, Equatable, Hashable, Sendable {
    public let retriedTurnID: UUID
    public let attempt: Int

    public init(retriedTurnID: UUID, attempt: Int = 1) {
        self.retriedTurnID = retriedTurnID
        self.attempt = max(1, attempt)
    }
}

/// A durable record for one admitted Turn.
public struct TurnRecord: Codable, Equatable, Sendable {
    public let identity: TurnIdentity
    public let threadID: UUID
    public let callerIntent: TurnCallerIntent
    /// The managed or direct path captured at admission.
    public let executionKind: TurnExecutionKind
    /// The Agent attached to the Thread when a managed Turn was admitted.
    public let capturedAgentID: UUID?
    public var lifecycle: TurnLifecycle
    public var currentModelRoundIndex: Int
    public var outcome: TurnOutcome?
    public var notices: [TurnNotice]
    public var correlations: [TurnCorrelation]
    public var retryRelation: TurnRetryRelation?
    public var recoveryRequired: Bool
    public var recoveryMessage: String?
    public var terminalHandle: TurnTerminalHandle?
    /// The assistant message that represents a completed Turn, when one exists.
    public var terminalMessageID: UUID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        identity: TurnIdentity,
        threadID: UUID,
        callerIntent: TurnCallerIntent,
        executionKind: TurnExecutionKind = .agentManaged,
        capturedAgentID: UUID? = nil,
        lifecycle: TurnLifecycle = .admitted,
        currentModelRoundIndex: Int? = nil,
        outcome: TurnOutcome? = nil,
        notices: [TurnNotice] = [],
        correlations: [TurnCorrelation] = [],
        retryRelation: TurnRetryRelation? = nil,
        recoveryRequired: Bool = false,
        recoveryMessage: String? = nil,
        terminalHandle: TurnTerminalHandle? = nil,
        terminalMessageID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.identity = identity
        self.threadID = threadID
        self.callerIntent = callerIntent
        self.executionKind = executionKind
        self.capturedAgentID = capturedAgentID
        self.lifecycle = lifecycle
        self.currentModelRoundIndex = currentModelRoundIndex ?? identity.modelRoundIndex
        self.outcome = outcome
        self.notices = notices
        self.correlations = correlations
        self.retryRelation = retryRelation
        self.recoveryRequired = recoveryRequired
        self.recoveryMessage = recoveryMessage
        self.terminalHandle = terminalHandle
        self.terminalMessageID = terminalMessageID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isTerminal: Bool {
        outcome != nil
    }
}

/// A stable handle resolved after a terminal outcome is durably recorded.
public struct TurnTerminalHandle: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let turnID: UUID

    public init(id: UUID = UUID(), turnID: UUID) {
        self.id = id
        self.turnID = turnID
    }
}

/// A durable intent written before a tool is allowed to execute.
public struct RuntimeToolIntent: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let turnID: UUID
    public let threadID: UUID
    public let toolCallID: String
    public let name: String
    public let arguments: String
    public let modelRoundIndex: Int
    public let workspaceID: UUID?
    public let workspaceRouting: WorkspaceToolRouting?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        turnID: UUID,
        threadID: UUID,
        toolCallID: String,
        name: String,
        arguments: String,
        modelRoundIndex: Int,
        workspaceID: UUID? = nil,
        workspaceRouting: WorkspaceToolRouting? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.turnID = turnID
        self.threadID = threadID
        self.toolCallID = toolCallID
        self.name = name
        self.arguments = arguments
        self.modelRoundIndex = modelRoundIndex
        self.workspaceID = workspaceID
        self.workspaceRouting = workspaceRouting
        self.createdAt = createdAt
    }
}

/// A durable tool result written before a subsequent model round can start.
public struct RuntimeToolResult: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let turnID: UUID
    public let threadID: UUID
    public let toolCallID: String
    public let output: String
    public let succeeded: Bool
    public let errorMessage: String?
    public let workspaceID: UUID?
    public let workspaceRouting: WorkspaceToolRouting?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        turnID: UUID,
        threadID: UUID,
        toolCallID: String,
        output: String,
        succeeded: Bool = true,
        errorMessage: String? = nil,
        workspaceID: UUID? = nil,
        workspaceRouting: WorkspaceToolRouting? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.turnID = turnID
        self.threadID = threadID
        self.toolCallID = toolCallID
        self.output = output
        self.succeeded = succeeded
        self.errorMessage = errorMessage
        self.workspaceID = workspaceID
        self.workspaceRouting = workspaceRouting
        self.createdAt = createdAt
    }
}

/// A summary projection. It is deliberately independent from prompt history and can only point
/// at already durable message IDs.
public struct ThreadSummary: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let threadID: UUID
    public let sourceMessageIDs: [UUID]
    public let text: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        threadID: UUID,
        sourceMessageIDs: [UUID],
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.sourceMessageIDs = sourceMessageIDs
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TurnAdmissionDisposition: String, Codable, Sendable {
    case admitted
    case joined
    case replayed
}

/// Result of an admission attempt. `.joined` and `.replayed` both return the original durable
/// record, allowing a host to attach to or replay a caller's existing Turn without creating a
/// second active execution.
public struct TurnAdmission: Codable, Equatable, Sendable {
    public let disposition: TurnAdmissionDisposition
    public let turn: TurnRecord

    public init(disposition: TurnAdmissionDisposition, turn: TurnRecord) {
        self.disposition = disposition
        self.turn = turn
    }
}

public enum TurnRecoveryResult: Codable, Equatable, Sendable {
    case noActiveTurn
    case active(TurnRecord)
    case recoveryRequired(TurnRecord)

    private enum CodingKeys: String, CodingKey { case kind, turn }
    private enum Kind: String, Codable { case noActiveTurn, active, recoveryRequired }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noActiveTurn:
            try container.encode(Kind.noActiveTurn, forKey: .kind)
        case let .active(turn):
            try container.encode(Kind.active, forKey: .kind)
            try container.encode(turn, forKey: .turn)
        case let .recoveryRequired(turn):
            try container.encode(Kind.recoveryRequired, forKey: .kind)
            try container.encode(turn, forKey: .turn)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .noActiveTurn:
            self = .noActiveTurn
        case .active:
            self = .active(try container.decode(TurnRecord.self, forKey: .turn))
        case .recoveryRequired:
            self = .recoveryRequired(try container.decode(TurnRecord.self, forKey: .turn))
        }
    }
}

/// Explicit confirmation required for the destructive administrative escape hatch. It clears
/// only the active pointer; durable Turns, messages, tool intents, and results remain intact.
public struct ForceClearConfirmation: Sendable, Equatable {
    public static let requiredPhrase = "FORCE_CLEAR"
    public let phrase: String

    public init(phrase: String) {
        self.phrase = phrase
    }
}

public enum ThreadRuntimeRepositoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case threadNotFound(UUID)
    case turnNotFound(UUID)
    case threadBusy(threadID: UUID, activeTurnID: UUID)
    case idempotencyConflict(requestID: UUID)
    case recoveryRequired(threadID: UUID, turnID: UUID)
    case invalidTransition(turnID: UUID, lifecycle: TurnLifecycle)
    case toolIntentRequired(turnID: UUID, toolCallID: String)
    case duplicateToolIntent(turnID: UUID, toolCallID: String)
    case duplicateToolResult(turnID: UUID, toolCallID: String)
    case appendOnlyViolation(messageID: UUID)
    case historyDeletionForbidden(threadID: UUID)
    case summarySourceMissing(messageID: UUID)
    case confirmationRequired
    case runtimeRepositoryRequired(threadID: UUID)
    case authorityCoordinatorRequired(threadID: UUID)

    public var description: String {
        switch self {
        case let .threadNotFound(id): return "Thread \(id) does not exist."
        case let .turnNotFound(id): return "Turn \(id) does not exist."
        case let .threadBusy(threadID, activeTurnID): return "Thread \(threadID) is busy with Turn \(activeTurnID)."
        case let .idempotencyConflict(requestID): return "Request \(requestID) was reused with a different caller intent."
        case let .recoveryRequired(threadID, turnID): return "Thread \(threadID) requires recovery for Turn \(turnID)."
        case let .invalidTransition(turnID, lifecycle): return "Turn \(turnID) cannot transition from \(lifecycle.rawValue)."
        case let .toolIntentRequired(turnID, toolCallID): return "Turn \(turnID) has no durable intent for tool call \(toolCallID)."
        case let .duplicateToolIntent(turnID, toolCallID): return "Turn \(turnID) already records tool call \(toolCallID)."
        case let .duplicateToolResult(turnID, toolCallID): return "Turn \(turnID) already records a result for tool call \(toolCallID)."
        case let .appendOnlyViolation(messageID): return "Message \(messageID) is append-only and cannot be replaced."
        case let .historyDeletionForbidden(threadID): return "Thread \(threadID) history is append-only and cannot be deleted."
        case let .summarySourceMissing(messageID): return "Summary source message \(messageID) is not durable."
        case .confirmationRequired: return "This administrative operation requires explicit FORCE_CLEAR confirmation."
        case let .runtimeRepositoryRequired(threadID): return "A ThreadRuntimeRepository is required to archive Thread \(threadID)."
        case let .authorityCoordinatorRequired(threadID): return "A ThreadAuthorityCoordinator is required to archive Thread \(threadID) safely."
        }
    }
}

// MARK: - Repository contract

/// The single behavioral owner of durable Thread history and Turn transitions.
///
/// Implementations must make each operation atomic at their storage boundary. Callers use the
/// returned success as the durable-before-side-effect barrier: provider requests and tool
/// execution begin only after their corresponding repository operation succeeds.
public protocol ThreadRuntimeRepository: ThreadPersistenceProtocol, ThreadMessageStoreProtocol {
    func admitTurn(
        threadID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        now: Date
    ) async throws -> TurnAdmission
    func admitRetry(
        threadID: UUID,
        previousTurnID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        attempt: Int,
        now: Date
    ) async throws -> TurnAdmission

    func fetchTurn(id: UUID) async throws -> TurnRecord?
    func fetchActiveTurn(for threadID: UUID) async throws -> TurnRecord?
    func appendNotice(turnID: UUID, notice: TurnNotice) async throws
    func appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date) async throws
    func fetchNotices(turnID: UUID) async throws -> [TurnNotice]
    func fetchCorrelations(turnID: UUID) async throws -> [TurnCorrelation]
    func beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date) async throws
    func recordProviderRequest(turnID: UUID, modelRoundIndex: Int, correlation: TurnCorrelation?, now: Date) async throws
    /// Records a tool intent before execution. A dispatcher may first write a route-neutral
    /// intent before resolving its admission snapshot, then write the same intent once more with
    /// resolved Workspace provenance; implementations must atomically replace that one
    /// route-neutral record with the enriched record while continuing to reject all other
    /// duplicate call IDs.
    func recordToolIntent(_ intent: RuntimeToolIntent) async throws
    func recordToolResult(_ result: RuntimeToolResult) async throws
    /// Atomically appends a durable tool message and records the corresponding result.
    /// Implementations must not expose either half of this transition to the next model round.
    func recordToolResult(_ result: RuntimeToolResult, message: ThreadMessage) async throws
    func fetchToolIntents(turnID: UUID) async throws -> [RuntimeToolIntent]
    func fetchToolResults(turnID: UUID) async throws -> [RuntimeToolResult]

    func completeTurn(
        turnID: UUID,
        outcome: TurnOutcome,
        finalMessage: ThreadMessage?,
        terminalHandle: TurnTerminalHandle?,
        now: Date
    ) async throws -> TurnRecord
    func failTurn(turnID: UUID, message: String, now: Date) async throws -> TurnRecord
    func cancelTurn(turnID: UUID, reason: String?, now: Date) async throws -> TurnRecord
    func interruptTurn(turnID: UUID, reason: String, force: Bool, now: Date) async throws -> TurnRecord
    func recover(threadID: UUID, now: Date) async throws -> TurnRecoveryResult
    func forceClear(threadID: UUID, confirmation: ForceClearConfirmation, now: Date) async throws -> TurnRecord?

    func saveSummary(_ summary: ThreadSummary) async throws
    func fetchSummaries(for threadID: UUID) async throws -> [ThreadSummary]
}

public extension ThreadRuntimeRepository {
    func admitTurn(
        threadID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        now: Date = Date()
    ) async throws -> TurnAdmission {
        try await admitTurn(
            threadID: threadID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            executionKind: .agentManaged,
            capturedAgentID: nil,
            turnID: UUID(),
            now: now
        )
    }

    func beginModelRound(turnID: UUID, modelRoundIndex: Int) async throws {
        try await beginModelRound(turnID: turnID, modelRoundIndex: modelRoundIndex, now: Date())
    }

    func recordProviderRequest(turnID: UUID, modelRoundIndex: Int, correlation: TurnCorrelation? = nil) async throws {
        try await recordProviderRequest(turnID: turnID, modelRoundIndex: modelRoundIndex, correlation: correlation, now: Date())
    }

    func completeTurn(
        turnID: UUID,
        outcome: TurnOutcome = .completed,
        finalMessage: ThreadMessage? = nil,
        terminalHandle: TurnTerminalHandle? = nil
    ) async throws -> TurnRecord {
        try await completeTurn(turnID: turnID, outcome: outcome, finalMessage: finalMessage, terminalHandle: terminalHandle, now: Date())
    }
}
