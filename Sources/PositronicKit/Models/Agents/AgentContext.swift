import Foundation
import ErrorKit
import PKContracts

/// Errors raised when an authoritative Agent context cannot be used for the admitted identity.
public enum AgentContextError: PKError, Equatable, Sendable {
    case identityMismatch(expected: UUID, actual: UUID)

    public var errorDomain: String { PKErrorDomain.context }

    public var errorCode: Int { 2001 }

    public var userFriendlyMessage: String {
        "The Agent context source returned context for a different Agent."
    }

    public var errorDescription: String? {
        switch self {
        case let .identityMismatch(expected, actual):
            return "Agent context identity mismatch: expected \(expected), received \(actual)."
        }
    }
}

/// The identity portion of the typed context supplied to a managed Turn.
public struct AgentContextIdentity: Codable, Equatable, Hashable, Sendable {
    public let agentID: UUID
    public let name: String
    public let description: String

    public init(agentID: UUID, name: String, description: String) {
        self.agentID = agentID
        self.name = name
        self.description = description
    }
}

/// A bounded continuity item supplied by an ``AgentContextSource``.
public struct AgentContextMemory: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let content: String
    public let source: String?
    /// Host-supplied ranking metadata. The runtime carries it into the captured snapshot without
    /// ordering or filtering on it.
    public let relevance: Double?

    public init(
        id: UUID = UUID(),
        content: String,
        source: String? = nil,
        relevance: Double? = nil
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.relevance = relevance
    }
}

/// A discoverable Markdown resource in an Agent's primary workspace.
///
/// The catalog is intentionally metadata-only. The file remains on disk and is read through the
/// Agent workspace file tools when the model needs its full contents.
public struct AgentContextResource: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let description: String

    public init(path: String, description: String) {
        self.id = path
        self.path = path
        self.description = description
    }
}

/// The immutable Agent continuity captured for one managed Turn.
///
/// The runtime owns the reserved prompt section mapping. Sources return typed data rather
/// than arbitrary prompt nodes, so a host can replace filesystem storage with a database,
/// remote service, or a no-memory implementation without changing Turn orchestration.
public struct AgentContextSnapshot: Codable, Equatable, Sendable {
    public let identity: AgentContextIdentity
    public let instructions: String
    public let memories: [AgentContextMemory]
    public let resources: [AgentContextResource]
    public let diagnostics: [TurnDiagnostic]
    public let primaryTimelineSummary: String?

    private enum CodingKeys: String, CodingKey {
        case identity, instructions, memories, resources, diagnostics
        case primaryTimelineSummary = "primaryThreadSummary"
    }

    public init(
        identity: AgentContextIdentity,
        instructions: String = "",
        memories: [AgentContextMemory] = [],
        resources: [AgentContextResource] = [],
        diagnostics: [TurnDiagnostic] = [],
        primaryTimelineSummary: String? = nil
    ) {
        self.identity = identity
        self.instructions = instructions
        self.memories = memories
        self.resources = resources
        self.diagnostics = diagnostics
        self.primaryTimelineSummary = primaryTimelineSummary
    }

    public init(
        agent: Agent,
        instructions: String = "",
        memories: [AgentContextMemory] = [],
        resources: [AgentContextResource] = [],
        diagnostics: [TurnDiagnostic] = [],
        primaryTimelineSummary: String? = nil
    ) {
        self.init(
            identity: AgentContextIdentity(
                agentID: agent.id,
                name: agent.name,
                description: agent.description
            ),
            instructions: instructions,
            memories: memories,
            resources: resources,
            diagnostics: diagnostics,
            primaryTimelineSummary: primaryTimelineSummary
        )
    }

}

/// Authoritative typed continuity source for managed Turns.
public protocol AgentContextSource: Sendable {
    func snapshot(for agent: Agent, timeline: TimelineRecord) async throws -> AgentContextSnapshot
}

public extension AgentContextSource {
    /// Descriptive alias for hosts that prefer “context” terminology at call sites.
    func context(for agent: Agent, timeline: TimelineRecord) async throws -> AgentContextSnapshot {
        try await snapshot(for: agent, timeline: timeline)
    }
}

/// Minimal source used by lower-level engine tests and hosts that do not configure continuity
/// storage. It preserves identity while making the absence of Agent memory explicit.
public struct IdentityAgentContextSource: AgentContextSource {
    public init() {}

    public func snapshot(for agent: Agent, timeline _: TimelineRecord) async throws -> AgentContextSnapshot {
        AgentContextSnapshot(agent: agent)
    }
}
