import Foundation

/// SCP-like URI for identifying workspaces
/// Format: `host:path` (e.g., `macbook:~/dev/project`, `monad-server:/sessions/abc123`)
public struct WorkspaceURI: Codable, Sendable, Hashable, CustomStringConvertible {
    public let host: String
    public let path: String

    public var description: String {
        "\(host):\(path)"
    }

    /// Whether this workspace is hosted on the server
    public var isServer: Bool {
        host.hasPrefix("monad-")
    }

    /// Whether this workspace is hosted on a client
    public var isClient: Bool {
        !isServer
    }

    public init(host: String, path: String) {
        self.host = host
        self.path = path
    }

    /// Parse a URI string like "hostname:/path/to/workspace"
    public init?(parsing uri: String) {
        guard let colonIndex = uri.firstIndex(of: ":") else { return nil }
        host = String(uri[..<colonIndex])
        path = String(uri[uri.index(after: colonIndex)...])
    }

    /// Create an agent workspace URI
    public static func agentWorkspace(_ agentId: UUID) -> WorkspaceURI {
        WorkspaceURI(host: "monad-server", path: "/agents/\(agentId.uuidString)")
    }

    /// Create a server timeline workspace URI
    public static func serverTimeline(_ timelineId: UUID) -> WorkspaceURI {
        WorkspaceURI(host: "monad-server", path: "/sessions/\(timelineId.uuidString)")
    }

    /// Create a client shell workspace URI
    public static func clientShell(hostname: String) -> WorkspaceURI {
        WorkspaceURI(host: hostname, path: "~")
    }

    /// Create a client project workspace URI
    public static func clientProject(hostname: String, path: String) -> WorkspaceURI {
        WorkspaceURI(host: hostname, path: path)
    }

    /// Create a git repository workspace URI
    public static func gitRepository(url: String) -> WorkspaceURI {
        WorkspaceURI(host: "git", path: url)
    }
}
