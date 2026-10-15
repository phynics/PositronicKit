import Foundation
import PKContracts

/// One durable historical message offered to a ``TurnHistoryProjectionSource``.
///
/// A descriptor is a host-neutral view of a message: the source sees the message identity,
/// role, canonical ordered content, token estimate, and the tool-call links needed to keep tool
/// transactions intact. A projection can only choose *which* historical messages to cover and
/// supply one bounded replacement; it cannot rewrite durable history.
public struct TurnHistoryMessageDescriptor: Codable, Equatable, Hashable, Sendable {
    /// The durable message identity, which is also the coverage key on ``TurnHistoryProjection``.
    public let id: UUID
    /// The message author role.
    public let role: Message.MessageRole
    /// The canonical ordered provider-facing content of the message.
    ///
    /// This preserves image and audio parts, so a source can cover a prefix that contains
    /// media faithfully. Use ``content`` for the text projection when text is enough.
    public let messageContent: MessageContent
    /// The text projection of ``messageContent``.
    ///
    /// This is a lossy convenience for text-only sources; it drops image and audio parts. Read
    /// ``messageContent`` to preserve them.
    public var content: String { messageContent.text }
    /// The runtime's token estimate for this message.
    ///
    /// The estimate is heuristic: it comes from `MessageContent.estimatedTokens`, which divides
    /// text length by four and applies fixed fallbacks for image and audio parts. It is a budget
    /// hint, not a provider tokenizer result. See ``TurnHistoryProjectionBudget``.
    public let estimatedTokens: Int
    /// For an assistant message, the tool-call IDs the message introduces, in order.
    public let toolCallIDs: [String]
    /// For a tool message, the tool-call ID this message answers.
    public let toolResultCallID: String?

    /// Creates a descriptor with canonical ordered multimodal content.
    public init(
        id: UUID,
        role: Message.MessageRole,
        messageContent: MessageContent,
        estimatedTokens: Int,
        toolCallIDs: [String] = [],
        toolResultCallID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.messageContent = messageContent
        self.estimatedTokens = estimatedTokens
        self.toolCallIDs = toolCallIDs
        self.toolResultCallID = toolResultCallID
    }

    /// Creates a text-only descriptor.
    ///
    /// This is a convenience for text-only callers and tests. Use the ``init(id:role:messageContent:estimatedTokens:toolCallIDs:toolResultCallID:)``
    /// overload to preserve image or audio parts.
    public init(
        id: UUID,
        role: Message.MessageRole,
        content: String,
        estimatedTokens: Int,
        toolCallIDs: [String] = [],
        toolResultCallID: String? = nil
    ) {
        self.init(
            id: id,
            role: role,
            messageContent: MessageContent(content),
            estimatedTokens: estimatedTokens,
            toolCallIDs: toolCallIDs,
            toolResultCallID: toolResultCallID
        )
    }
}

/// Budget metadata for one ``TurnHistoryProjectionRequest``.
///
/// The projection runs before structured budget compression, so the source can decide coverage
/// against the same prompt budget the runtime will later honor.
///
/// - Important: Every token value here is a runtime *estimate*, not a provider tokenizer count.
///   `contextWindowTokens` and `reserveForResponse` come from the configured provider metadata,
///   but `availableTokens` is their difference and `historyTokens` is the sum of the heuristic
///   ``TurnHistoryMessageDescriptor/estimatedTokens`` values. The real wire cost can differ, so a
///   source should treat `availableTokens` as an upper bound and leave its own margin rather than
///   fitting a checkpoint exactly to it.
public struct TurnHistoryProjectionBudget: Codable, Equatable, Hashable, Sendable {
    /// The model's full context-window size in tokens, from provider metadata.
    public let contextWindowTokens: Int
    /// Tokens withheld from the context window for the model response and provider overhead.
    public let reserveForResponse: Int
    /// Estimated tokens available to the whole prompt: `contextWindowTokens - reserveForResponse`.
    public let availableTokens: Int
    /// The estimated token sum across the offered historical messages.
    ///
    /// This is the sum of the heuristic ``TurnHistoryMessageDescriptor/estimatedTokens`` values,
    /// not a tokenizer result.
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
    /// The durable ID of the most recent message the runtime already covered with a projection on
    /// an earlier Turn of this Timeline, or `nil` when no earlier projection is in effect.
    ///
    /// The value is an exclusive coverage watermark: descriptors at or before `since` were offered
    /// to the source before, so a source that keeps its own checkpoint can skip re-deriving them
    /// instead of treating every Turn as cold. The watermark is process-scoped with the runtime's
    /// prompt bookkeeping; it is `nil` on the first projected Turn and after a restart. ``messages``
    /// is always the full offered history so coverage can still be validated.
    public let since: UUID?
    /// The durable historical messages preceding this Turn's current input, in transcript order.
    public let messages: [TurnHistoryMessageDescriptor]
    public let budget: TurnHistoryProjectionBudget

    public init(
        timelineID: UUID,
        turnID: UUID,
        requestID: UUID,
        agentID: UUID?,
        executionKind: TurnExecutionKind,
        since: UUID? = nil,
        messages: [TurnHistoryMessageDescriptor],
        budget: TurnHistoryProjectionBudget
    ) {
        self.timelineID = timelineID
        self.turnID = turnID
        self.requestID = requestID
        self.agentID = agentID
        self.executionKind = executionKind
        self.since = since
        self.messages = messages
        self.budget = budget
    }
}

/// A bounded replacement for a covered historical prefix.
///
/// The result expresses coverage, not an arbitrary prompt. The runtime renders the replacement
/// as one semi-stable section with a stable identity, keeps the retained tail in original order,
/// and never lets a host change the current input, system instructions, or tool schemas.
///
/// - Important: ``replacement`` is deliberately plain text. Flat carry replaces covered history
///   with a bounded textual checkpoint; it cannot carry structured or media content. This was a
///   recorded 7.0 decision: a multimodal replacement would complicate the semi-stable prompt
///   identity and prefix-reset accounting for no flat-carry benefit. Use the retained raw tail for
///   any history whose media must reach the provider faithfully.
public struct TurnHistoryProjection: Codable, Equatable, Hashable, Sendable {
    /// The maximum replacement length the runtime accepts, in characters.
    ///
    /// The cap keeps a checkpoint bounded and the semi-stable section small. A longer replacement
    /// is rejected with ``TurnHistoryProjectionError/replacementTooLarge(limit:)`` rather than
    /// silently truncated.
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
/// This is the stable 7.0 contract external context managers use to replace a covered prefix with
/// one bounded checkpoint. The source runs during Turn preparation, before budget compression, and
/// receives ordered ``TurnHistoryMessageDescriptor`` values plus budget metadata. A source may
/// return `nil` to leave the history unchanged for that Turn, and a source that throws follows its
/// ``failureRequirement``. Durable history is never rewritten.
///
/// Known, recorded 7.0 boundaries:
/// - Descriptors carry multimodal ``TurnHistoryMessageDescriptor/messageContent``; the checkpoint
///   replacement stays plain text (``TurnHistoryProjection/replacement``).
/// - ``TurnHistoryProjectionRequest/since`` is a process-scoped watermark, not durable state.
/// - Budget metadata is heuristic; see ``TurnHistoryProjectionBudget``.
public protocol TurnHistoryProjectionSource: Sendable {
    /// Declares how a failure from this source affects the admitted Turn.
    /// Projection sources default to optional: a failed projection falls back to raw history.
    var failureRequirement: TurnContextContributionRequirement { get }
    func projection(for request: TurnHistoryProjectionRequest) async throws -> TurnHistoryProjection?
}

public extension TurnHistoryProjectionSource {
    var failureRequirement: TurnContextContributionRequirement { .optional }
}
