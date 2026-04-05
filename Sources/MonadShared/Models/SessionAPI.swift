import Foundation

public struct CreateTimelineRequest: Codable, Sendable {
    public let title: String?

    public init(title: String? = nil) {
        self.title = title
    }
}

public struct UpdateSessionTitleRequest: Codable, Sendable {
    public let title: String

    public init(title: String) {
        self.title = title
    }
}

public struct TimelineWorkspacesResponse: Codable, Sendable {
    public let primaryWorkspace: WorkspaceReference?
    public let attachedWorkspaces: [WorkspaceReference]

    public init(primaryWorkspace: WorkspaceReference?, attachedWorkspaces: [WorkspaceReference]) {
        self.primaryWorkspace = primaryWorkspace
        self.attachedWorkspaces = attachedWorkspaces
    }
}

public struct TimelineResponse: Codable, Sendable, Identifiable {
    public let id: UUID
    public let title: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let isArchived: Bool
    public let workingDirectory: String?
    public let attachedWorkspaceIds: [UUID]
    public let attachedAgentInstanceId: UUID?

    public init(
        id: UUID,
        title: String?,
        createdAt: Date,
        updatedAt: Date,
        isArchived: Bool,
        workingDirectory: String?,
        attachedWorkspaceIds: [UUID],
        attachedAgentInstanceId: UUID?
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.workingDirectory = workingDirectory
        self.attachedWorkspaceIds = attachedWorkspaceIds
        self.attachedAgentInstanceId = attachedAgentInstanceId
    }

    public init(id: UUID, title: String?) {
        self.id = id
        self.title = title
        createdAt = Date()
        updatedAt = Date()
        isArchived = false
        workingDirectory = nil
        attachedWorkspaceIds = []
        attachedAgentInstanceId = nil
    }
}

public struct UpdateTimelineRequest: Codable, Sendable {
    public let title: String?

    public init(title: String? = nil) {
        self.title = title
    }
}
