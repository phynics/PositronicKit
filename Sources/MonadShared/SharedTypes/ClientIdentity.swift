import Foundation

// MARK: - Client Identity

/// Represents a registered client that can connect to the server
public struct ClientIdentity: Codable, Sendable, Identifiable {
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

    /// Default shell workspace URI for this client
    public var shellWorkspaceURI: WorkspaceURI {
        WorkspaceURI.clientShell(hostname: hostname)
    }
}
