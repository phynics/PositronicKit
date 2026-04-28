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
    public var location: WorkspaceLocation
    public let originId: UUID? // RequestOriginIdentity.id or nil for runtime-owned
    public var tools: [ToolReference] // Tools available in this workspace
    public var rootPath: String? // Filesystem root for the workspace
    public var trustLevel: WorkspaceTrustLevel
    public var lastModifiedBy: UUID? // Timeline ID that last modified
    public var status: WorkspaceStatus
    public var metadata: [String: AnyCodable]
    public var contextInjection: String?
    public let createdAt: Date

    public enum WorkspaceLocation: String, Codable, Sendable {
        case runtime
        case runtimeTimeline // A workspace specific to a timeline in this runtime
        case attached

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            switch rawValue {
            case "runtime": self = .runtime
            case "runtimeTimeline": self = .runtimeTimeline
            case "attached": self = .attached
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown WorkspaceLocation: \(rawValue)"
                )
            }
        }
    }

    public enum WorkspaceStatus: String, Codable, Sendable {
        case active
        case missing
        case unknown
    }

    public init(
        id: UUID = UUID(),
        uri: WorkspaceURI,
        location: WorkspaceLocation,
        originId: UUID? = nil,
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
        self.location = location
        self.originId = originId
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
            location: location,
            originId: originId,
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
            uri: .timelineWorkspace(timelineId),
            location: .runtime,
            rootPath: rootPath,
            trustLevel: .full,
            metadata: metadata
        )
    }
}
