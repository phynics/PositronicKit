import Foundation

/// Durable lifecycle of an Agent identity.
public enum AgentLifecycleState: String, Codable, Sendable, Equatable {
    /// The Agent may be attached and may admit managed Turns.
    case active
    /// The Agent is draining admitted Turns and cannot admit new managed Turns.
    case retiring
    /// The Agent is no longer available for managed execution.
    case retired
}

/// A live agent entity with its own workspace and private timeline.
///
/// `Agent` is created from an `AgentTemplate` template (which provides initial instructions),
/// but is self-contained — it holds its own identity and durable resource ownership without
/// referencing the source template. Instructions and continuity are resolved through the
/// configured `AgentContextSource` at managed Turn admission.
public struct Agent: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID

    /// Display name for this Agent.
    public var name: String

    /// Purpose description for this Agent.
    public var description: String

    /// Durable lifecycle state used to gate managed Turn admission.
    public var lifecycle: AgentLifecycleState

    /// The agent's private workspace — where root SOUL.md and persistent Notes/ files live.
    /// This is the agent's memory across timelines.
    public var primaryWorkspaceID: UUID?

    /// The agent's private timeline (internal monologue / cross-agent inbox).
    /// Created atomically with the instance. Never nil after creation.
    public let privateTimelineID: UUID

    /// Updated on every chat generation turn for activity tracking.
    public var lastActiveAt: Date

    public let createdAt: Date
    public var updatedAt: Date

    /// Reserved for future use: wakeup triggers, capabilities, etc.
    public var metadata: [String: AnyCodable]

    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        lifecycle: AgentLifecycleState = .active,
        primaryWorkspaceID: UUID? = nil,
        privateTimelineID: UUID,
        lastActiveAt: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: AnyCodable] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.lifecycle = lifecycle
        self.primaryWorkspaceID = primaryWorkspaceID
        self.privateTimelineID = privateTimelineID
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }


    private enum CodingKeys: String, CodingKey {
        case id, name, description, lifecycle
        case primaryWorkspaceID = "primaryWorkspaceId"
        case privateTimelineID = "privateThreadId"
        case lastActiveAt, createdAt, updatedAt, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            description: try container.decode(String.self, forKey: .description),
            lifecycle: try container.decodeIfPresent(AgentLifecycleState.self, forKey: .lifecycle) ?? .active,
            primaryWorkspaceID: try container.decodeIfPresent(UUID.self, forKey: .primaryWorkspaceID),
            privateTimelineID: try container.decode(UUID.self, forKey: .privateTimelineID),
            lastActiveAt: try container.decode(Date.self, forKey: .lastActiveAt),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            metadata: try container.decode([String: AnyCodable].self, forKey: .metadata)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encodeIfPresent(primaryWorkspaceID, forKey: .primaryWorkspaceID)
        try container.encode(privateTimelineID, forKey: .privateTimelineID)
        try container.encode(lastActiveAt, forKey: .lastActiveAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(metadata, forKey: .metadata)
    }
}
