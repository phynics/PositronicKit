import Foundation

/// A live agent entity with its own workspace and private thread.
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
    public var primaryWorkspaceID: UUID?

    /// The agent's private thread (internal monologue / cross-agent inbox).
    /// Created atomically with the instance. Never nil after creation.
    public let privateThreadID: UUID

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
        primaryWorkspaceID: UUID? = nil,
        privateThreadID: UUID,
        lastActiveAt: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: AnyCodable] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.primaryWorkspaceID = primaryWorkspaceID
        self.privateThreadID = privateThreadID
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    /// Creates an agent instance using the legacy identifier spellings.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
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
        self.init(
            id: id,
            name: name,
            description: description,
            primaryWorkspaceID: primaryWorkspaceId,
            privateThreadID: privateTimelineId,
            lastActiveAt: lastActiveAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadata: metadata
        )
    }

    /// Creates an agent instance using the legacy identifier spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        primaryWorkspaceID: UUID? = nil,
        privateTimelineID: UUID,
        lastActiveAt: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: AnyCodable] = [:]
    ) {
        self.init(
            id: id,
            name: name,
            description: description,
            primaryWorkspaceID: primaryWorkspaceID,
            privateThreadID: privateTimelineID,
            lastActiveAt: lastActiveAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            metadata: metadata
        )
    }

    /// The primary-workspace identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "primaryWorkspaceID")
    public var primaryWorkspaceId: UUID? {
        get { primaryWorkspaceID }
        set { primaryWorkspaceID = newValue }
    }

    /// The private-timeline identifier using the legacy 3.x spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var privateTimelineID: UUID { privateThreadID }

    /// The private-thread identifier using the legacy 3.x spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var privateTimelineId: UUID { privateThreadID }

    private enum CodingKeys: String, CodingKey {
        case id, name, description
        case primaryWorkspaceID = "primaryWorkspaceId"
        case privateThreadID = "privateTimelineId"
        case lastActiveAt, createdAt, updatedAt, metadata
    }
}
