import Foundation

/// A live agent entity with its own workspace and private timeline.
///
/// `AgentInstance` is created from an `AgentTemplate` template (which provides initial instructions),
/// but is self-contained — it holds its own copies of configuration and does not reference
/// the source template. Instructions are loaded at runtime from workspace files
/// (`Notes/system.md`, `Notes/persona.md`) rather than stored on the struct.
public struct AgentInstance: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID

    /// Display name for this instance
    public var name: String

    /// Purpose description for this instance
    public var description: String

    /// The agent's private workspace — where Notes/system.md, Notes/persona.md, and other
    /// persistent files live. This is the agent's memory across timelines.
    public var primaryWorkspaceId: UUID?

    /// The agent's private timeline (internal monologue / cross-agent inbox).
    /// Created atomically with the instance. Never nil after creation.
    public let privateTimelineId: UUID

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
        primaryWorkspaceId: UUID? = nil,
        privateTimelineId: UUID,
        lastActiveAt: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: AnyCodable] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.primaryWorkspaceId = primaryWorkspaceId
        self.privateTimelineId = privateTimelineId
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}
