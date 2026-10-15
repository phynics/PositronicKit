import Foundation
import PKContracts
import PKUtilities

/// A durable timeline with messages.
public struct TimelineRecord: Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isArchived: Bool
    public var workingDirectory: String?

    /// The agent currently attached to this timeline (holds the generation lock).
    /// Multiple timelines can reference the same agent. Each timeline can have at most one agent.
    public var attachedAgentID: UUID?

    /// True for an agent-private timeline (internal monologue / cross-agent inbox).
    /// Private timelines are excluded from general listing.
    public var isPrivate: Bool

    /// True for a Timeline whose lifetime is owned by live handles rather than by durable
    /// storage.
    ///
    /// The runtime deletes an ephemeral Timeline and its messages when the last handle to it is
    /// released, and sweeps orphaned ephemeral Timelines at runtime start. Ephemeral Timelines
    /// are excluded from ``TimelineCapability/list(includeArchived:includeEphemeral:)`` by
    /// default. Absent on decode means `false` so records persisted before this field existed
    /// round-trip unchanged.
    public var isEphemeral: Bool

    /// Lineage for a Timeline created by forking another Timeline. `nil` for an ordinary
    /// Timeline.
    public var forkedFrom: TimelineForkOrigin?

    public init(
        id: UUID = UUID(),
        title: String = "New Timeline",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isArchived: Bool = false,
        workingDirectory: String? = nil,
        attachedAgentID: UUID? = nil,
        isPrivate: Bool = false,
        isEphemeral: Bool = false,
        forkedFrom: TimelineForkOrigin? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.workingDirectory = workingDirectory
        self.attachedAgentID = attachedAgentID
        self.isPrivate = isPrivate
        self.isEphemeral = isEphemeral
        self.forkedFrom = forkedFrom
    }

}

// MARK: - Codable

extension TimelineRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, isArchived, workingDirectory
        case attachedAgentID = "attachedAgentId"
        case isPrivate, isEphemeral, forkedFrom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        attachedAgentID = try container.decodeIfPresent(UUID.self, forKey: .attachedAgentID)
        isPrivate = (try? container.decode(Bool.self, forKey: .isPrivate)) ?? false
        isEphemeral = (try? container.decode(Bool.self, forKey: .isEphemeral)) ?? false
        forkedFrom = try container.decodeIfPresent(TimelineForkOrigin.self, forKey: .forkedFrom)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encodeIfPresent(attachedAgentID, forKey: .attachedAgentID)
        try container.encode(isPrivate, forKey: .isPrivate)
        try container.encode(isEphemeral, forKey: .isEphemeral)
        try container.encodeIfPresent(forkedFrom, forKey: .forkedFrom)
    }
}
