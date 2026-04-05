import Foundation
import MonadShared

/// A conversation timeline with messages
public struct Timeline: Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isArchived: Bool
    public var workingDirectory: String?
    public var attachedWorkspaceIds: [UUID]

    /// The agent instance currently attached to this timeline (holds the generation lock).
    /// Multiple timelines can reference the same agent. Each timeline can have at most one agent.
    public var attachedAgentInstanceId: UUID?

    /// True for agent private timelines (internal monologue / cross-agent inbox).
    /// Private timelines are excluded from general listing.
    public var isPrivate: Bool

    public init(
        id: UUID = UUID(),
        title: String = "New Conversation",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isArchived: Bool = false,
        workingDirectory: String? = nil,
        attachedWorkspaceIds: [UUID] = [],
        attachedAgentInstanceId: UUID? = nil,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.workingDirectory = workingDirectory
        self.attachedWorkspaceIds = attachedWorkspaceIds
        self.attachedAgentInstanceId = attachedAgentInstanceId
        self.isPrivate = isPrivate
    }
}

// MARK: - Codable

extension Timeline: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, isArchived, workingDirectory
        case attachedWorkspaceIds
        case attachedAgentInstanceId, isPrivate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        attachedAgentInstanceId = try container.decodeIfPresent(UUID.self, forKey: .attachedAgentInstanceId)
        isPrivate = (try? container.decode(Bool.self, forKey: .isPrivate)) ?? false

        // DB stores as JSON string; JSON contexts may provide an array — handle both
        if let jsonString = try? container.decode(String.self, forKey: .attachedWorkspaceIds),
           let data = jsonString.data(using: .utf8),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            attachedWorkspaceIds = ids
        } else {
            attachedWorkspaceIds = (try? container.decode([UUID].self, forKey: .attachedWorkspaceIds)) ?? []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encodeIfPresent(attachedAgentInstanceId, forKey: .attachedAgentInstanceId)
        try container.encode(isPrivate, forKey: .isPrivate)

        // Encode as JSON string for DB storage
        let jsonString: String
        if let data = try? JSONEncoder().encode(attachedWorkspaceIds),
           let str = String(data: data, encoding: .utf8) {
            jsonString = str
        } else {
            jsonString = "[]"
        }
        try container.encode(jsonString, forKey: .attachedWorkspaceIds)
    }
}
