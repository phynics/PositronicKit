import Foundation
import PKContracts

/// One durable historical message offered to a ``TurnHistoryProjectionSource``.
///
/// A descriptor is a host-neutral view of a message: the source sees the message identity,
/// role, provider-facing content, token estimate, and the tool-call links needed to keep tool
/// transactions intact. A projection can only choose *which* historical messages to cover and
/// supply one bounded replacement; it cannot rewrite durable history.
public struct TurnHistoryMessageDescriptor: Codable, Equatable, Hashable, Sendable {
    /// The durable message identity, which is also the coverage key on ``TurnHistoryProjection``.
    public let id: UUID
    /// The message author role.
    public let role: Message.MessageRole
    /// The provider-facing text content of the message.
    public let content: String
    /// The runtime's token estimate for this message.
    public let estimatedTokens: Int
    /// For an assistant message, the tool-call IDs the message introduces, in order.
    public let toolCallIDs: [String]
    /// For a tool message, the tool-call ID this message answers.
    public let toolResultCallID: String?

    public init(
        id: UUID,
        role: Message.MessageRole,
        content: String,
        estimatedTokens: Int,
        toolCallIDs: [String] = [],
        toolResultCallID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.estimatedTokens = estimatedTokens
        self.toolCallIDs = toolCallIDs
        self.toolResultCallID = toolResultCallID
    }
}

/// Budget metadata for one ``TurnHistoryProjectionRequest``.
///
/// The projection runs before PKPrompt structured budget compression, so the source can decide
/// coverage against the same prompt budget the compressor will later honor.
public struct TurnHistoryProjectionBudget: Codable, Equatable, Hashable, Sendable {
    /// The model's full context-window size in tokens.
    public let contextWindowTokens: Int
    /// Tokens withheld from the context window for the model response and provider overhead.
    public let reserveForResponse: Int
    /// Tokens available to the whole prompt: `contextWindowTokens - reserveForResponse`.
    public let availableTokens: Int
    /// The runtime's token estimate across the offered historical messages.
    public let historyTokens: Int

    public init(
        contextWindowTokens: Int,
        reserveForResponse: Int,
        availableTokens: Int,
        historyTokens: Int
    ) {
        self.contextWindowTokens = contextWindowTokens
        self.reserveForResponse = reserveForResponse
        self.availableTokens = availableTokens
        self.historyTokens = historyTokens
    }
}

/// Immutable identity and ordered historical descriptors supplied to a
/// ``TurnHistoryProjectionSource`` for one admitted Turn.
public struct TurnHistoryProjectionRequest: Codable, Equatable, Hashable, Sendable {
    public let timelineID: UUID
    public let turnID: UUID
    public let requestID: UUID
    public let agentID: UUID?
    public let executionKind: TurnExecutionKind
    /// The durable historical messages preceding this Turn's current input, in transcript order.
    public let messages: [TurnHistoryMessageDescriptor]
    public let budget: TurnHistoryProjectionBudget

    public init(
        timelineID: UUID,
        turnID: UUID,
        requestID: UUID,
        agentID: UUID?,
        executionKind: TurnExecutionKind,
        messages: [TurnHistoryMessageDescriptor],
        budget: TurnHistoryProjectionBudget
    ) {
        self.timelineID = timelineID
        self.turnID = turnID
        self.requestID = requestID
        self.agentID = agentID
        self.executionKind = executionKind
        self.messages = messages
        self.budget = budget
    }
}

/// A bounded replacement for a covered historical prefix.
///
/// The result expresses coverage, not an arbitrary prompt. The runtime renders the replacement
/// as one semi-stable section with a stable identity, keeps the retained tail in original order,
/// and never lets a host change the current input, system instructions, or tool schemas.
public struct TurnHistoryProjection: Codable, Equatable, Hashable, Sendable {
    /// The maximum replacement length the runtime accepts.
    public static let maximumReplacementCharacters = 32_768

    /// The durable IDs of the covered prefix, in transcript order. Coverage must be a
    /// contiguous prefix of the offered history.
    public let coveredMessageIDs: [UUID]
    /// The bounded replacement text.
    public let replacement: String
    /// The durable ID of the first offered message retained raw after coverage, or `nil` when
    /// coverage extends to the end of the offered history.
    public let firstRetainedMessageID: UUID?

    public init(
        coveredMessageIDs: [UUID],
        replacement: String,
        firstRetainedMessageID: UUID?
    ) {
        self.coveredMessageIDs = coveredMessageIDs
        self.replacement = replacement
        self.firstRetainedMessageID = firstRetainedMessageID
    }
}

/// Errors raised while validating a host-provided historical projection.
///
/// Every case is structural: the runtime rejects coverage it cannot apply without changing the
/// meaning of the Turn rather than silently dropping or reordering history.
public enum TurnHistoryProjectionError: Error, Equatable, Sendable, LocalizedError {
    /// The projection covered no messages.
    case emptyCoverage
    /// Coverage named a message that is not in the offered history.
    case unknownMessageID(UUID)
    /// Coverage was not the contiguous prefix of the offered history.
    case nonContiguousCoverage(expected: UUID, actual: UUID)
    /// The first retained message did not match the message after the covered prefix.
    case firstRetainedMismatch(expected: UUID?, actual: UUID?)
    /// Coverage would split an assistant tool call from its result.
    case splitToolTransaction(messageID: UUID)
    /// Coverage named the current Turn input, which the host cannot project.
    case coversCurrentInput(UUID)
    /// The replacement exceeded ``TurnHistoryProjection/maximumReplacementCharacters``.
    case replacementTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyCoverage:
            return "A historical projection must cover at least one message."
        case let .unknownMessageID(id):
            return "A historical projection covered message '\(id.uuidString)', which is not in the offered history."
        case let .nonContiguousCoverage(expected, actual):
            return "A historical projection must cover a contiguous prefix; expected '\(expected.uuidString)' but covered '\(actual.uuidString)'."
        case let .firstRetainedMismatch(expected, actual):
            return "The first retained message '\(actual?.uuidString ?? "<nil>")' does not follow the covered prefix (expected '\(expected?.uuidString ?? "<nil>")')."
        case let .splitToolTransaction(id):
            return "A historical projection would split the tool transaction at message '\(id.uuidString)'."
        case let .coversCurrentInput(id):
            return "A historical projection cannot cover the current Turn input '\(id.uuidString)'."
        case let .replacementTooLarge(limit):
            return "A historical projection replacement exceeds the \(limit)-character limit."
        }
    }
}

/// Supplies a bounded, provider-facing representation of a covered historical prefix for one Turn.
///
/// The source runs during Turn preparation, before PKPrompt structured budget compression, and
/// receives only descriptors and budget metadata. A source may return `nil` to leave the history
/// unchanged for that Turn. Durable history is never rewritten.
public protocol TurnHistoryProjectionSource: Sendable {
    /// Declares how a failure from this source affects the admitted Turn.
    /// Projection sources default to optional: a failed projection falls back to raw history.
    var failureRequirement: TurnContextContributionRequirement { get }
    func projection(for request: TurnHistoryProjectionRequest) async throws -> TurnHistoryProjection?
}

public extension TurnHistoryProjectionSource {
    var failureRequirement: TurnContextContributionRequirement { .optional }
}
