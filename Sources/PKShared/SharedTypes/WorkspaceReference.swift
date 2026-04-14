import Foundation

public enum WorkspaceTrustLevel: String, Codable, Sendable {
    case full // Unrestricted within boundary
    case restricted // Allowlist of operations
    case readOnly // Read-only filesystem operations
}

/// A workspace reference defines the metadata and location of a workspace
public struct WorkspaceReference: Codable, Sendable, Identifiable {
    public let id: UUID
    public let uri: WorkspaceURI
    public var hostType: WorkspaceHostType
    public let ownerId: UUID? // ClientIdentity.id or nil for server-owned
    public var tools: [ToolReference] // Tools available in this workspace
    public var rootPath: String? // Filesystem root for the workspace
    public var trustLevel: WorkspaceTrustLevel
    public var lastModifiedBy: UUID? // Timeline ID that last modified
    public var status: WorkspaceStatus
    public var metadata: [String: AnyCodable]
    public var contextInjection: String?
    public let createdAt: Date

    public enum WorkspaceHostType: String, Codable, Sendable {
        case server
        case serverTimeline // A workspace specific to a timeline on the server
        case client
    }

    public enum WorkspaceStatus: String, Codable, Sendable {
        case active
        case missing
        case unknown
    }

    public init(
        id: UUID = UUID(),
        uri: WorkspaceURI,
        hostType: WorkspaceHostType,
        ownerId: UUID? = nil,
        tools: [ToolReference] = [],
        rootPath: String? = nil,
        trustLevel: WorkspaceTrustLevel = .full,
        lastModifiedBy: UUID? = nil,
        status: WorkspaceStatus = .active,
        metadata: [String: AnyCodable] = [:],
        contextInjection: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.uri = uri
        self.hostType = hostType
        self.ownerId = ownerId
        self.tools = tools
        self.rootPath = rootPath
        self.trustLevel = trustLevel
        self.lastModifiedBy = lastModifiedBy
        self.status = status
        self.metadata = metadata
        self.contextInjection = contextInjection
        self.createdAt = createdAt
    }

    /// Returns a copy of this workspace with the given tools, preserving all other fields.
    public func withTools(_ newTools: [ToolReference]) -> WorkspaceReference {
        WorkspaceReference(
            id: id,
            uri: uri,
            hostType: hostType,
            ownerId: ownerId,
            tools: newTools,
            rootPath: rootPath,
            trustLevel: trustLevel,
            lastModifiedBy: lastModifiedBy,
            status: status,
            metadata: metadata,
            contextInjection: contextInjection,
            createdAt: createdAt
        )
    }

    /// Create a primary workspace for a timeline
    public static func primaryForTimeline(
        _ timelineId: UUID,
        rootPath: String,
        metadata: [String: AnyCodable] = [:]
    ) -> WorkspaceReference {
        WorkspaceReference(
            uri: .serverTimeline(timelineId),
            hostType: .server,
            rootPath: rootPath,
            trustLevel: .full,
            metadata: metadata
        )
    }
}
