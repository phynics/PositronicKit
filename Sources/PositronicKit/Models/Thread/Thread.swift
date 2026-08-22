import Foundation
import PKContracts
import PKUtilities

/// A durable thread thread with messages.
public struct Thread: Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isArchived: Bool
    public var workingDirectory: String?

    /// The agent currently attached to this thread (holds the generation lock).
    /// Multiple threads can reference the same agent. Each thread can have at most one agent.
    public var attachedAgentID: UUID?

    /// True for an agent-private thread (internal monologue / cross-agent inbox).
    /// Private threads are excluded from general listing.
    public var isPrivate: Bool

    public init(
        id: UUID = UUID(),
        title: String = "New Thread",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isArchived: Bool = false,
        workingDirectory: String? = nil,
        attachedAgentID: UUID? = nil,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.workingDirectory = workingDirectory
        self.attachedAgentID = attachedAgentID
        self.isPrivate = isPrivate
    }

}

// MARK: - Codable

extension Thread: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, isArchived, workingDirectory
        case attachedAgentID = "attachedAgentId"
        case isPrivate
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
    }
}
