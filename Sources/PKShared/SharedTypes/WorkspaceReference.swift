import Foundation

/// How much a tool/workspace consumer is permitted to do within a workspace's boundary.
public enum WorkspaceTrustLevel: String, Codable, Sendable {
    /// Unrestricted operations within the workspace boundary.
    case full // Unrestricted within boundary
    /// Only an allowlisted set of operations is permitted.
    case restricted // Allowlist of operations
    /// Only read-only filesystem operations are permitted.
    case readOnly // Read-only filesystem operations
}

/// A workspace reference defines the metadata and location of a workspace
public struct WorkspaceReference: Codable, Sendable, Identifiable {
    public let id: UUID
    public let uri: WorkspaceURI
    public var location: WorkspaceLocation
    /// The identity that requested this workspace be created (`RequestOriginIdentity.id`),
    /// or `nil` for workspaces the runtime owns/creates itself.
    public let originID: UUID? // RequestOriginIdentity.id or nil for runtime-owned
    /// Tools available in this workspace
    public var tools: [ToolReference] // Tools available in this workspace
    /// Filesystem root for the workspace
    public var rootPath: String? // Filesystem root for the workspace
    public var trustLevel: WorkspaceTrustLevel
    /// The id of the thread that last modified this workspace, if any.
    public var lastModifiedBy: UUID? // Thread ID that last modified
    public var status: WorkspaceStatus
    /// Optional extra text injected into the prompt context when this workspace is active.
    public var contextInjection: String?
    public let createdAt: Date

    /// Where a workspace lives relative to the runtime.
    public enum WorkspaceLocation: Codable, Sendable, Equatable {
        /// A workspace owned directly by the runtime, not tied to a specific timeline.
        case runtime
        /// A workspace specific to a thread in this runtime.
        case runtimeThread
        /// A workspace specific to a timeline in this runtime.
        @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
        case runtimeTimeline
        /// A workspace attached from outside the runtime (e.g. an existing filesystem location).
        case attached

        public var rawValue: String {
            switch self {
            case .runtime: "runtime"
            case .runtimeThread, .runtimeTimeline: "runtimeTimeline"
            case .attached: "attached"
            }
        }

        public init?(rawValue: String) {
            switch rawValue {
            case "runtime": self = .runtime
            case "runtimeTimeline", "runtimeThread": self = .runtimeThread
            case "attached": self = .attached
            default: return nil
            }
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.runtimeThread, .runtimeThread), (.runtimeTimeline, .runtimeTimeline),
                 (.runtimeThread, .runtimeTimeline), (.runtimeTimeline, .runtimeThread):
                true
            default:
                lhs.rawValue == rhs.rawValue
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let location = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown WorkspaceLocation: \(rawValue)"
                )
            }
            self = location
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Whether the workspace's underlying storage is currently reachable.
    public enum WorkspaceStatus: String, Codable, Sendable {
        /// The workspace is present and usable.
        case active
        /// The workspace's underlying location could not be found (e.g. deleted on disk).
        case missing
        /// Status has not yet been determined.
        case unknown
    }

    public init(
        id: UUID = UUID(),
        uri: WorkspaceURI,
        location: WorkspaceLocation,
        originID: UUID? = nil,
        tools: [ToolReference] = [],
        rootPath: String? = nil,
        trustLevel: WorkspaceTrustLevel = .full,
        lastModifiedBy: UUID? = nil,
        status: WorkspaceStatus = .active,
        contextInjection: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.uri = uri
        self.location = location
        self.originID = originID
        self.tools = tools
        self.rootPath = rootPath
        self.trustLevel = trustLevel
        self.lastModifiedBy = lastModifiedBy
        self.status = status
        self.contextInjection = contextInjection
        self.createdAt = createdAt
    }

    /// Creates a workspace reference using the legacy identifier spelling.
    @_disfavoredOverload
    @available(*, deprecated, message: "Use init(..., originID:...).")
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
        contextInjection: String? = nil,
        createdAt: Date = Date()
    ) {
        self.init(
            id: id,
            uri: uri,
            location: location,
            originID: originId,
            tools: tools,
            rootPath: rootPath,
            trustLevel: trustLevel,
            lastModifiedBy: lastModifiedBy,
            status: status,
            contextInjection: contextInjection,
            createdAt: createdAt
        )
    }

    /// The request-origin identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "originID")
    public var originId: UUID? { originID }

    /// Returns a copy of this workspace with the given tools, preserving all other fields.
    public func withTools(_ newTools: [ToolReference]) -> WorkspaceReference {
        WorkspaceReference(
            id: id,
            uri: uri,
            location: location,
            originID: originID,
            tools: newTools,
            rootPath: rootPath,
            trustLevel: trustLevel,
            lastModifiedBy: lastModifiedBy,
            status: status,
            contextInjection: contextInjection,
            createdAt: createdAt
        )
    }

    /// Creates a primary workspace for a thread.
    public static func makePrimary(
        forThread threadID: UUID,
        rootPath: String
    ) -> WorkspaceReference {
        WorkspaceReference(
            uri: .threadWorkspace(threadID),
            location: .runtime,
            rootPath: rootPath,
            trustLevel: .full
        )
    }

    /// Creates a primary workspace for a timeline using the legacy API spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public static func makePrimary(
        forTimeline timelineID: UUID,
        rootPath: String
    ) -> WorkspaceReference {
        makePrimary(forThread: timelineID, rootPath: rootPath)
    }

    /// Creates a primary workspace for a timeline using the legacy API spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public static func primaryForTimeline(
        _ timelineId: UUID,
        rootPath: String
    ) -> WorkspaceReference {
        makePrimary(forThread: timelineId, rootPath: rootPath)
    }
}

private extension WorkspaceReference {
    enum CodingKeys: String, CodingKey {
        case id, uri, location
        case originID = "originId"
        case tools, rootPath, trustLevel, lastModifiedBy, status, contextInjection, createdAt
    }
}
