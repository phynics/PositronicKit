import Foundation

// MARK: - Request Origin Identity

/// Represents a registered request origin known to the runtime.
public struct RequestOriginIdentity: Codable, Sendable, Identifiable {
    public let id: UUID
    public let hostname: String
    public let displayName: String
    public let platform: String  // "macos", "linux", "ios", "web", etc.
    public let registeredAt: Date
    public var lastSeenAt: Date?

    public init(
        id: UUID = UUID(),
        hostname: String,
        displayName: String,
        platform: String,
        registeredAt: Date = Date(),
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.hostname = hostname
        self.displayName = displayName
        self.platform = platform
        self.registeredAt = registeredAt
        self.lastSeenAt = lastSeenAt
    }

    /// Default shell workspace URI for this origin.
    public var shellWorkspaceURI: WorkspaceURI {
        WorkspaceURI.clientShell(hostname: hostname)
    }
}
