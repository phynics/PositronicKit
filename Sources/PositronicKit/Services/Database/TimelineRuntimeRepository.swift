import Foundation
import PKContracts
import PKUtilities

// MARK: - Turn durability vocabulary

/// The caller-owned identity used to make turn admission idempotent.
///
/// A fingerprint is deliberately opaque to the repository. The caller computes it from the
/// complete intent that it considers retry-equivalent; the repository compares it byte for byte
/// for active and successfully completed requests, while unsuccessful terminal attempts may be
/// admitted again as linked retries.
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
public enum TurnOutcome: Codable, Equatable, Hashable, Sendable {
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

/// The operator action required before a quarantined Timeline accepts new work.
///
/// A Turn is quarantined only when interrupting it could leave an unrepeatable side effect: it
/// has an unresolved tool intent for a `.mutating` or `.externalProcess` tool. A quarantined
/// Timeline rejects admission until an operator confirms that the side effect was reconciled.
public struct TurnQuarantine: Codable, Equatable, Hashable, Sendable {
    public let reason: String
    public let createdAt: Date

    public init(reason: String, createdAt: Date = Date()) {
        self.reason = reason
        self.createdAt = createdAt
    }
}

/// A durable record for one admitted Turn.
public struct TurnRecord: Codable, Equatable, Sendable {
    public let identity: TurnIdentity
    public let timelineID: UUID
    public let callerIntent: TurnCallerIntent
    /// The managed or direct path captured at admission.
    public let executionKind: TurnExecutionKind
    /// The Agent attached to the Timeline when a managed Turn was admitted.
    public let capturedAgentID: UUID?
    public var lifecycle: TurnLifecycle
    public var currentModelRoundIndex: Int
    public var outcome: TurnOutcome?
    public var notices: [TurnNotice]
    public var correlations: [TurnCorrelation]
    public var retryRelation: TurnRetryRelation?
    /// Non-nil only for an interrupted Turn whose side effects still require operator review.
    public var quarantine: TurnQuarantine?
    public var terminalHandle: TurnTerminalHandle?
    /// The assistant message that represents a completed Turn, when one exists.
    public var terminalMessageID: UUID?
    public let createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case identity
        case timelineID = "threadID"
        case callerIntent, executionKind, capturedAgentID, lifecycle, currentModelRoundIndex
        case outcome, notices, correlations, retryRelation, quarantine
        case terminalHandle, terminalMessageID, createdAt, updatedAt
    }

    public init(
        identity: TurnIdentity,
        timelineID: UUID,
        callerIntent: TurnCallerIntent,
        executionKind: TurnExecutionKind = .agentManaged,
        capturedAgentID: UUID? = nil,
        lifecycle: TurnLifecycle = .admitted,
        currentModelRoundIndex: Int? = nil,
        outcome: TurnOutcome? = nil,
        notices: [TurnNotice] = [],
        correlations: [TurnCorrelation] = [],
        retryRelation: TurnRetryRelation? = nil,
        quarantine: TurnQuarantine? = nil,
        terminalHandle: TurnTerminalHandle? = nil,
        terminalMessageID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.identity = identity
        self.timelineID = timelineID
        self.callerIntent = callerIntent
        self.executionKind = executionKind
        self.capturedAgentID = capturedAgentID
        self.lifecycle = lifecycle
        self.currentModelRoundIndex = currentModelRoundIndex ?? identity.modelRoundIndex
        self.outcome = outcome
        self.notices = notices
        self.correlations = correlations
        self.retryRelation = retryRelation
        self.quarantine = quarantine
        self.terminalHandle = terminalHandle
        self.terminalMessageID = terminalMessageID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isTerminal: Bool {
        outcome != nil
    }

    /// Whether this Turn blocks new admission until an operator releases it.
    public var isQuarantined: Bool {
        quarantine != nil
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
    public let timelineID: UUID
    public let toolCallID: String
    public let name: String
    public let arguments: String
    public let modelRoundIndex: Int
    /// The tool's declared side-effect class at intent time. Liveness uses it to decide whether
    /// interrupting an abandoned Turn may repeat a side effect, without needing the tool to be
    /// registered again (ADR 0010).
    public let sideEffects: ToolSideEffects
    public let workspaceID: UUID?
    public let workspaceRouting: WorkspaceToolRouting?
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, turnID
        case timelineID = "threadID"
        case toolCallID, name, arguments, modelRoundIndex, sideEffects, workspaceID, workspaceRouting, createdAt
    }

    public init(
        id: UUID = UUID(),
        turnID: UUID,
        timelineID: UUID,
        toolCallID: String,
        name: String,
        arguments: String,
        modelRoundIndex: Int,
        sideEffects: ToolSideEffects = .mutating,
        workspaceID: UUID? = nil,
        workspaceRouting: WorkspaceToolRouting? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.turnID = turnID
        self.timelineID = timelineID
        self.toolCallID = toolCallID
        self.name = name
        self.arguments = arguments
        self.modelRoundIndex = modelRoundIndex
        self.sideEffects = sideEffects
        self.workspaceID = workspaceID
        self.workspaceRouting = workspaceRouting
        self.createdAt = createdAt
    }
}

/// A durable tool result written before a subsequent model round can start.
///
/// `output` is the single payload: the tool's success output, or the model-facing failure text
/// (`"Error: …"` plus any remediation) when `isSuccessful` is `false`.
public struct RuntimeToolResult: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let turnID: UUID
    public let timelineID: UUID
    public let toolCallID: String
    public let output: String
    public let isSuccessful: Bool
    public let workspaceID: UUID?
    public let workspaceRouting: WorkspaceToolRouting?
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, turnID
        case timelineID = "threadID"
        case toolCallID, output, isSuccessful, workspaceID, workspaceRouting, createdAt
    }

    public init(
        id: UUID = UUID(),
        turnID: UUID,
        timelineID: UUID,
        toolCallID: String,
        output: String,
        isSuccessful: Bool = true,
        workspaceID: UUID? = nil,
        workspaceRouting: WorkspaceToolRouting? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.turnID = turnID
        self.timelineID = timelineID
        self.toolCallID = toolCallID
        self.output = output
        self.isSuccessful = isSuccessful
        self.workspaceID = workspaceID
        self.workspaceRouting = workspaceRouting
        self.createdAt = createdAt
    }
}

/// A summary projection. It is deliberately independent from prompt history and can only point
/// at already durable message IDs.
///
/// Host-managed: the runtime neither writes nor reads summaries. A host summary pipeline stores
/// them through ``TimelineRuntimeRepository/saveSummary(_:)`` and reads them back with
/// ``TimelineRuntimeRepository/fetchSummaries(for:)``. The
/// ``AgentContextSnapshot/primaryTimelineSummary`` prompt section is supplied by the Agent context
/// source, not derived from these rows.
public struct TimelineSummary: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let timelineID: UUID
    public let sourceMessageIDs: [UUID]
    public let text: String
    public let createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case timelineID = "threadID"
        case sourceMessageIDs, text, createdAt, updatedAt
    }

    public init(
        id: UUID = UUID(),
        timelineID: UUID,
        sourceMessageIDs: [UUID],
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.timelineID = timelineID
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

/// Why the runtime is recording an abandoned Turn.
///
/// A `.retryable` interruption releases the Timeline so the same request ID may be retried as a
/// linked attempt. A `.quarantined` interruption blocks admission until an operator releases it,
/// because retrying could repeat a side effect the runtime cannot prove was not started.
public enum TurnInterruptDisposition: Equatable, Hashable, Sendable {
    case retryable
    case quarantined(String)
}

/// The durable result of an interruption attempt.
///
/// Both cases are first-writer-wins: `.alreadyTerminal` reports the record the Turn's own owner
/// committed before the interruption arrived, and never overwrites it.
public enum TurnInterruptResult: Codable, Equatable, Sendable {
    case interrupted(TurnRecord)
    case alreadyTerminal(TurnRecord)

    private enum CodingKeys: String, CodingKey { case kind, turn }
    private enum Kind: String, Codable { case interrupted, alreadyTerminal }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .interrupted(turn):
            try container.encode(Kind.interrupted, forKey: .kind)
            try container.encode(turn, forKey: .turn)
        case let .alreadyTerminal(turn):
            try container.encode(Kind.alreadyTerminal, forKey: .kind)
            try container.encode(turn, forKey: .turn)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .interrupted:
            self = .interrupted(try container.decode(TurnRecord.self, forKey: .turn))
        case .alreadyTerminal:
            self = .alreadyTerminal(try container.decode(TurnRecord.self, forKey: .turn))
        }
    }

    public var record: TurnRecord {
        switch self {
        case let .interrupted(turn), let .alreadyTerminal(turn):
            return turn
        }
    }
}

/// Explicit operator confirmation required before a quarantined Timeline accepts new work. It
/// clears only the quarantine marker; the interrupted Turn, its messages, tool intents, and
/// results remain intact as the audit trail for the side effect.
public struct QuarantineReleaseConfirmation: Sendable, Equatable {
    public static let requiredPhrase = "RELEASE_QUARANTINE"
    public let phrase: String

    public init(phrase: String) {
        self.phrase = phrase
    }
}

public enum TimelineRuntimeRepositoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case timelineNotFound(UUID)
    case turnNotFound(UUID)
    case timelineBusy(timelineID: UUID, activeTurnID: UUID)
    case idempotencyConflict(requestID: UUID)
    case timelineQuarantined(timelineID: UUID, turnID: UUID)
    case invalidTransition(turnID: UUID, lifecycle: TurnLifecycle)
    case toolIntentRequired(turnID: UUID, toolCallID: String)
    case duplicateToolIntent(turnID: UUID, toolCallID: String)
    case duplicateToolResult(turnID: UUID, toolCallID: String)
    case appendOnlyViolation(messageID: UUID)
    case historyDeletionForbidden(timelineID: UUID)
    case summarySourceMissing(messageID: UUID)
    case confirmationRequired
    case runtimeRepositoryRequired(timelineID: UUID)
    case authorityCoordinatorRequired(timelineID: UUID)
    case inputMessageTimelineMismatch(messageID: UUID, expectedTimelineID: UUID, actualTimelineID: UUID)
    case finalMessageTimelineMismatch(messageID: UUID, expectedTimelineID: UUID, actualTimelineID: UUID)
    case quarantineNotFound(timelineID: UUID, turnID: UUID)

    private struct ErrorMetadata {
        let code: Int
        let message: String
    }

    private var errorMetadata: ErrorMetadata {
        switch self {
        case let .timelineNotFound(id):
            return ErrorMetadata(code: 6101, message: "Timeline \(id) does not exist.")
        case let .turnNotFound(id):
            return ErrorMetadata(code: 6102, message: "Turn \(id) does not exist.")
        case let .timelineBusy(timelineID, activeTurnID):
            return ErrorMetadata(code: 6103, message: "Timeline \(timelineID) is busy with Turn \(activeTurnID).")
        case let .idempotencyConflict(requestID):
            return ErrorMetadata(code: 6104, message: "Request \(requestID) was reused with a different caller intent.")
        case let .timelineQuarantined(timelineID, turnID):
            return ErrorMetadata(code: 6105, message: "Timeline \(timelineID) is quarantined for Turn \(turnID).")
        case let .invalidTransition(turnID, lifecycle):
            return ErrorMetadata(code: 6106, message: "Turn \(turnID) cannot transition from \(lifecycle.rawValue).")
        case let .toolIntentRequired(turnID, toolCallID):
            return ErrorMetadata(code: 6107, message: "Turn \(turnID) has no durable intent for tool call \(toolCallID).")
        case let .duplicateToolIntent(turnID, toolCallID):
            return ErrorMetadata(code: 6108, message: "Turn \(turnID) already records tool call \(toolCallID).")
        case let .duplicateToolResult(turnID, toolCallID):
            return ErrorMetadata(code: 6109, message: "Turn \(turnID) already records a result for tool call \(toolCallID).")
        case let .appendOnlyViolation(messageID):
            return ErrorMetadata(code: 6110, message: "Message \(messageID) is append-only and cannot be replaced.")
        case let .historyDeletionForbidden(timelineID):
            return ErrorMetadata(code: 6111, message: "Timeline \(timelineID) history is append-only and cannot be deleted.")
        case let .summarySourceMissing(messageID):
            return ErrorMetadata(code: 6112, message: "Summary source message \(messageID) is not durable.")
        case .confirmationRequired:
            return ErrorMetadata(code: 6113, message: "This administrative operation requires explicit FORCE_CLEAR confirmation.")
        case let .runtimeRepositoryRequired(timelineID):
            return ErrorMetadata(code: 6114, message: "A TimelineRuntimeRepository is required to archive Timeline \(timelineID).")
        case let .authorityCoordinatorRequired(timelineID):
            return ErrorMetadata(code: 6115, message: "A TimelineAuthorityCoordinator is required to archive Timeline \(timelineID) safely.")
        case let .inputMessageTimelineMismatch(messageID, expectedTimelineID, actualTimelineID):
            return ErrorMetadata(
                code: 6116,
                message: "Input message \(messageID) belongs to Timeline \(actualTimelineID), not Timeline \(expectedTimelineID)."
            )
        case let .finalMessageTimelineMismatch(messageID, expectedTimelineID, actualTimelineID):
            return ErrorMetadata(
                code: 6117,
                message: "Final message \(messageID) belongs to Timeline \(actualTimelineID), not Timeline \(expectedTimelineID)."
            )
        case let .quarantineNotFound(timelineID, turnID):
            return ErrorMetadata(
                code: 6118,
                message: "Timeline \(timelineID) has no quarantined Turn \(turnID) to release."
            )
        }
    }

    public var description: String {
        errorMetadata.message
    }
}

/// Stable `PKError` identity for Timeline runtime repository failures.
extension TimelineRuntimeRepositoryError: PKError {
    public var errorDomain: String {
        PKErrorDomain.timeline
    }

    public var errorCode: Int {
        errorMetadata.code
    }

    public var userFriendlyMessage: String {
        errorMetadata.message
    }
}

// MARK: - Repository contract

/// The single behavioral owner of durable Timeline history and Turn transitions.
///
/// Implementations must make each operation atomic at their storage boundary. Admission is one
/// transaction: when `inputMessage` is non-nil, the new Turn, its active pointer, Request-ID
/// uniqueness record, and input message become visible together. A failed admission must expose
/// none of those records. If a caller loses the response after the transaction commits, retrying
/// the same Request ID and fingerprint must return the existing Turn and must not append the input
/// message again. Callers use the returned success as the durable-before-side-effect barrier:
/// provider requests and tool execution begin only after their corresponding repository operation
/// succeeds.
///
/// ## History deletion cascade
///
/// `deleteTimeline(id:)` (inherited from ``TimelinePersistenceProtocol``) MUST cascade: destroying a
/// Deleting a Timeline destroys its durable history and summary projections along with it. Append-only (ADR
/// 0003) means a Timeline's history is immutable *while the Timeline lives*, not that it survives the
/// Timeline's own deletion — a conformer that drops the timeline row but leaves `messages`/summaries
/// behind creates an unbounded, unreachable-by-ID storage leak and a data-retention problem for
/// any content the deleted Timeline carried. `deleteMessages(for:)` remains forbidden for ordinary
/// in-place history pruning (`TimelineRuntimeRepositoryError.historyDeletionForbidden`); the only
/// sanctioned path to removing a Timeline's messages is deleting the Timeline itself. A SQL-backed
/// conformer typically satisfies this with `ON DELETE CASCADE` foreign keys from messages/summary
/// tables to the timeline row; an in-memory or other keyed-store conformer must remove the
/// corresponding per-timeline entries explicitly inside `deleteTimeline(id:)`.
///
/// `PKTestSupport` ships `TimelineRuntimeRepositoryConformanceSuite` for downstream adapters. The
/// suite exercises these durable admission, history, ordering, interruption, and terminal-transition
/// invariants without making the support library a test-discovery target.
public protocol TimelineRuntimeRepository: TimelinePersistenceProtocol, TimelineMessageStoreProtocol {
    func admitTurn(
        timelineID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        now: Date
    ) async throws -> TurnAdmission
    func admitRetry(
        timelineID: UUID,
        previousTurnID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage?,
        executionKind: TurnExecutionKind,
        capturedAgentID: UUID?,
        turnID: UUID,
        attempt: Int,
        now: Date
    ) async throws -> TurnAdmission

    func fetchTurn(id: UUID) async throws -> TurnRecord?
    func fetchActiveTurn(for timelineID: UUID) async throws -> TurnRecord?
    /// Appends host-facing metadata without changing the Turn outcome. Notices may be recorded
    /// after terminal completion so best-effort customization failures remain observable.
    func appendNotice(turnID: UUID, notice: TurnNotice) async throws
    func appendCorrelation(turnID: UUID, correlation: TurnCorrelation, now: Date) async throws
    func fetchNotices(turnID: UUID) async throws -> [TurnNotice]
    func fetchCorrelations(turnID: UUID) async throws -> [TurnCorrelation]
    func beginModelRound(turnID: UUID, modelRoundIndex: Int, now: Date) async throws
    func recordProviderRequest(turnID: UUID, modelRoundIndex: Int, correlation: TurnCorrelation?, now: Date) async throws
    func recordToolIntent(_ intent: RuntimeToolIntent) async throws
    func recordToolResult(_ result: RuntimeToolResult) async throws
    /// Atomically appends a durable tool message and records the corresponding result.
    /// Implementations must not expose either half of this transition to the next model round.
    func recordToolResult(_ result: RuntimeToolResult, message: TimelineMessage) async throws
    func fetchToolIntents(turnID: UUID) async throws -> [RuntimeToolIntent]
    func fetchToolResults(turnID: UUID) async throws -> [RuntimeToolResult]

    /// Atomically appends `finalMessage` (when supplied) and records the terminal outcome.
    /// Normal terminal assistant messages must use this boundary rather than a separate message
    /// store write, and the message must belong to the Turn's Timeline. Repeating the operation for
    /// an already-terminal Turn returns its durable record without appending a second message.
    ///
    /// This is the only operation that records a terminal outcome for a Turn. It is
    /// first-writer-wins: a late caller for an already-terminal Turn observes the durable record
    /// unchanged, so a slow store can never overwrite an interruption that landed first.
    func completeTurn(
        turnID: UUID,
        outcome: TurnOutcome,
        finalMessage: TimelineMessage?,
        terminalHandle: TurnTerminalHandle?,
        now: Date
    ) async throws -> TurnRecord
    /// Records an abandoned Turn. This is the only operation that interrupts an active Turn.
    ///
    /// It is first-writer-wins: when the Turn's own owner already committed a terminal outcome,
    /// the implementation returns `.alreadyTerminal` with that record and changes nothing. A
    /// `.quarantined` disposition also persists a ``TurnQuarantine`` that blocks admission until
    /// ``releaseQuarantine(timelineID:turnID:confirmation:now:)`` is called.
    func interruptTurn(
        turnID: UUID,
        reason: String,
        disposition: TurnInterruptDisposition,
        now: Date
    ) async throws -> TurnInterruptResult
    /// Releases a quarantined Timeline after an operator reconciled the interrupted Turn's
    /// side effects. Throws `confirmationRequired` when `confirmation` is not the required phrase.
    func releaseQuarantine(
        timelineID: UUID,
        turnID: UUID,
        confirmation: QuarantineReleaseConfirmation,
        now: Date
    ) async throws -> TurnRecord

    func saveSummary(_ summary: TimelineSummary) async throws
    func fetchSummaries(for timelineID: UUID) async throws -> [TimelineSummary]
}

public extension TimelineRuntimeRepository {
    func admitTurn(
        timelineID: UUID,
        requestID: UUID,
        callerIntentFingerprint: String,
        inputMessage: TimelineMessage? = nil,
        now: Date = Date()
    ) async throws -> TurnAdmission {
        try await admitTurn(
            timelineID: timelineID,
            requestID: requestID,
            callerIntentFingerprint: callerIntentFingerprint,
            inputMessage: inputMessage,
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
        finalMessage: TimelineMessage? = nil,
        terminalHandle: TurnTerminalHandle? = nil
    ) async throws -> TurnRecord {
        try await completeTurn(turnID: turnID, outcome: outcome, finalMessage: finalMessage, terminalHandle: terminalHandle, now: Date())
    }

    /// Convenience over ``completeTurn(turnID:outcome:finalMessage:terminalHandle:now:)`` for a
    /// failed Turn. Not a repository requirement: a conformer implements only `completeTurn`.
    func failTurn(turnID: UUID, message: String, now: Date = Date()) async throws -> TurnRecord {
        try await completeTurn(
            turnID: turnID,
            outcome: .failed(message: message),
            finalMessage: nil,
            terminalHandle: nil,
            now: now
        )
    }

    /// Convenience over ``completeTurn(turnID:outcome:finalMessage:terminalHandle:now:)`` for a
    /// cancelled Turn. Not a repository requirement: a conformer implements only `completeTurn`.
    func cancelTurn(turnID: UUID, reason: String?, now: Date = Date()) async throws -> TurnRecord {
        try await completeTurn(
            turnID: turnID,
            outcome: .cancelled(reason: reason),
            finalMessage: nil,
            terminalHandle: nil,
            now: now
        )
    }
}
