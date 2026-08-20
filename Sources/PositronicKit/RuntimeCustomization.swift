import Foundation
import PKContracts

/// Whether a context contribution failure changes the meaning of a Turn.
public enum TurnContextContributionRequirement: String, Codable, Equatable, Hashable, Sendable {
    /// A failed contribution aborts preparation before provider work begins.
    case required
    /// A failed contribution is recorded as a host-facing notice and the Turn continues.
    case optional
}

/// The bounded value kinds a ``TurnContextContribution`` may carry.
public enum TurnContextContributionValue: Codable, Equatable, Hashable, Sendable {
    case text(String)
    case json(AnyCodable)

    public var textValue: String {
        switch self {
        case let .text(value): return value
        case let .json(value): return value.description
        }
    }
}

/// Errors raised while validating a host-provided Turn context contribution.
public enum TurnContextContributionError: Error, Equatable, Sendable, LocalizedError {
    case emptyNamespace
    case reservedNamespace(String)
    case invalidNamespace(String)
    case emptyKey
    case invalidKey(String)
    case textTooLarge(limit: Int)
    case jsonTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyNamespace:
            return "Turn context contribution namespace cannot be empty."
        case let .reservedNamespace(namespace):
            return "Turn context contribution namespace '\(namespace)' is reserved for PositronicKit."
        case let .invalidNamespace(namespace):
            return "Turn context contribution namespace '\(namespace)' is invalid."
        case .emptyKey:
            return "Turn context contribution key cannot be empty."
        case let .invalidKey(key):
            return "Turn context contribution key '\(key)' is invalid."
        case let .textTooLarge(limit):
            return "Turn context contribution text exceeds the \(limit)-character limit."
        case let .jsonTooLarge(limit):
            return "Turn context contribution JSON exceeds the \(limit)-byte limit."
        }
    }
}

/// A bounded, namespaced value contributed to one Turn's prompt context.
///
/// Contributions are rendered as host-owned context notes. They cannot replace the prompt tree,
/// register arbitrary pipeline stages, or inject runtime tools. Namespaces beginning with a
/// PositronicKit-reserved name are rejected so host data cannot overwrite runtime sections.
public struct TurnContextContribution: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let maximumTextCharacters = 32_768
    public static let maximumJSONBytes = 65_536

    public let id: UUID
    public let namespace: String
    public let key: String
    public let value: TurnContextContributionValue
    public let requirement: TurnContextContributionRequirement

    public init(
        namespace: String,
        key: String,
        value: TurnContextContributionValue,
        requirement: TurnContextContributionRequirement = .optional,
        id: UUID = UUID()
    ) throws {
        let normalizedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedNamespace.isEmpty else { throw TurnContextContributionError.emptyNamespace }
        guard Self.isValidNamespace(normalizedNamespace) else {
            throw TurnContextContributionError.invalidNamespace(namespace)
        }
        guard !Self.isReservedNamespace(normalizedNamespace) else {
            throw TurnContextContributionError.reservedNamespace(normalizedNamespace)
        }

        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw TurnContextContributionError.emptyKey }
        guard Self.isValidKey(normalizedKey) else {
            throw TurnContextContributionError.invalidKey(key)
        }

        switch value {
        case let .text(text):
            guard text.count <= Self.maximumTextCharacters else {
                throw TurnContextContributionError.textTooLarge(limit: Self.maximumTextCharacters)
            }
        case let .json(json):
            let data = try JSONEncoder().encode(json)
            guard data.count <= Self.maximumJSONBytes else {
                throw TurnContextContributionError.jsonTooLarge(limit: Self.maximumJSONBytes)
            }
        }

        self.id = id
        self.namespace = normalizedNamespace
        self.key = normalizedKey
        self.value = value
        self.requirement = requirement
    }

    public init(
        namespace: String,
        key: String,
        text: String,
        requirement: TurnContextContributionRequirement = .optional,
        id: UUID = UUID()
    ) throws {
        try self.init(
            namespace: namespace,
            key: key,
            value: .text(text),
            requirement: requirement,
            id: id
        )
    }

    public init(
        namespace: String,
        key: String,
        json: AnyCodable,
        requirement: TurnContextContributionRequirement = .optional,
        id: UUID = UUID()
    ) throws {
        try self.init(
            namespace: namespace,
            key: key,
            value: .json(json),
            requirement: requirement,
            id: id
        )
    }

    public var source: String { "runtime/\(namespace)/\(key)" }
    public var noteName: String { "\(namespace).\(key)" }

    private static func isValidNamespace(_ value: String) -> Bool {
        value.split(separator: ".").allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        }
    }

    private static func isValidKey(_ value: String) -> Bool {
        value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    private static func isReservedNamespace(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return ["positronickit", "runtime", "system"].contains { reserved in
            lowered == reserved || lowered.hasPrefix("\(reserved).")
        }
    }
}

/// Immutable identity supplied to a ``TurnContextSource`` for one admitted Turn.
public struct TurnContextRequest: Codable, Equatable, Hashable, Sendable {
    public let threadID: UUID
    public let turnID: UUID
    public let requestID: UUID
    public let agentID: UUID?
    public let executionKind: TurnExecutionKind
    public let message: String
    public let contributors: [TurnContributor]

    public init(
        threadID: UUID,
        turnID: UUID,
        requestID: UUID,
        agentID: UUID?,
        executionKind: TurnExecutionKind,
        message: String,
        contributors: [TurnContributor] = []
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.requestID = requestID
        self.agentID = agentID
        self.executionKind = executionKind
        self.message = message
        self.contributors = contributors
    }
}

/// Supplies bounded, namespaced context values for a Turn.
public protocol TurnContextSource: Sendable {
    /// Declares how a failure from this source affects the admitted Turn.
    /// Sources default to required so a missing context dependency fails closed.
    var failureRequirement: TurnContextContributionRequirement { get }
    func contributions(for request: TurnContextRequest) async throws -> [TurnContextContribution]
}

public extension TurnContextSource {
    var failureRequirement: TurnContextContributionRequirement { .required }
}

/// A lifecycle fact delivered to an optional ``AgentActivitySink``.
public struct AgentActivity: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case turnStarted
        case turnFinished
        case turnFailed
        case turnCancelled
    }

    public let kind: Kind
    public let threadID: UUID
    public let turnID: UUID
    public let requestID: UUID
    public let agentID: UUID?
    public let modelRoundIndex: Int
    public let detail: String?

    public init(
        kind: Kind,
        threadID: UUID,
        turnID: UUID,
        requestID: UUID,
        agentID: UUID?,
        modelRoundIndex: Int,
        detail: String? = nil
    ) {
        self.kind = kind
        self.threadID = threadID
        self.turnID = turnID
        self.requestID = requestID
        self.agentID = agentID
        self.modelRoundIndex = modelRoundIndex
        self.detail = detail
    }
}

/// Best-effort sink for Agent lifecycle activity.
public protocol AgentActivitySink: Sendable {
    func record(_ activity: AgentActivity) async throws
}

/// Durable terminal outcome delivered after the runtime repository accepts it.
public struct TurnOutcomeRecord: Codable, Equatable, Hashable, Sendable {
    public let threadID: UUID
    public let turnID: UUID
    public let requestID: UUID
    public let agentID: UUID?
    public let executionKind: TurnExecutionKind
    public let modelRoundIndex: Int
    public let outcome: TurnOutcome

    public init(
        threadID: UUID,
        turnID: UUID,
        requestID: UUID,
        agentID: UUID?,
        executionKind: TurnExecutionKind,
        modelRoundIndex: Int,
        outcome: TurnOutcome
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.requestID = requestID
        self.agentID = agentID
        self.executionKind = executionKind
        self.modelRoundIndex = modelRoundIndex
        self.outcome = outcome
    }
}

/// Best-effort sink invoked only after a terminal outcome is durable.
public protocol TurnOutcomeSink: Sendable {
    func record(_ outcome: TurnOutcomeRecord) async throws
}

/// The four bounded runtime customization roles accepted by the facade.
public struct RuntimeCustomization: Sendable {
    public let agentContextSource: (any AgentContextSource)?
    public let turnContextSource: (any TurnContextSource)?
    public let agentActivitySink: (any AgentActivitySink)?
    public let turnOutcomeSink: (any TurnOutcomeSink)?

    public init(
        agentContextSource: (any AgentContextSource)? = nil,
        turnContextSource: (any TurnContextSource)? = nil,
        agentActivitySink: (any AgentActivitySink)? = nil,
        turnOutcomeSink: (any TurnOutcomeSink)? = nil
    ) {
        self.agentContextSource = agentContextSource
        self.turnContextSource = turnContextSource
        self.agentActivitySink = agentActivitySink
        self.turnOutcomeSink = turnOutcomeSink
    }

    public static let `default` = RuntimeCustomization()
}

/// Stable host-facing codes for nonfatal runtime customization notices.
public enum TurnNoticeCode: String, Codable, Equatable, Hashable, Sendable {
    case contextContributionFailed = "runtime.context-contribution-failed"
    case agentActivitySinkFailed = "runtime.agent-activity-sink-failed"
    case turnOutcomeSinkFailed = "runtime.turn-outcome-sink-failed"
}
