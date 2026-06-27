import Foundation

/// SCP-like URI for identifying workspaces
/// Format: `host:path` (e.g., `macbook:~/dev/project`, `pk-runtime:/timelines/abc123`)
public struct WorkspaceURI: Codable, Sendable, Hashable, CustomStringConvertible {
    public let host: String
    public let path: String

    public var description: String {
        "\(host):\(path)"
    }

    /// Whether this workspace is hosted by the runtime
    public var isRuntime: Bool {
        host.hasPrefix("pk-")
    }

    /// Whether this workspace is hosted externally
    public var isExternal: Bool {
        !isRuntime
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
        WorkspaceURI(host: "pk-runtime", path: "/agents/\(agentId.uuidString)")
    }

    /// Create a timeline workspace URI owned by this runtime
    public static func timelineWorkspace(_ timelineId: UUID) -> WorkspaceURI {
        WorkspaceURI(host: "pk-runtime", path: "/timelines/\(timelineId.uuidString)")
    }

    /// Create a request-origin shell workspace URI.
    public static func requestOriginShell(hostname: String) -> WorkspaceURI {
        WorkspaceURI(host: hostname, path: "~")
    }

    /// Create a request-origin project workspace URI.
    public static func requestOriginProject(hostname: String, path: String) -> WorkspaceURI {
        WorkspaceURI(host: hostname, path: path)
    }

    /// Create a git repository workspace URI
    public static func gitRepository(url: String) -> WorkspaceURI {
        WorkspaceURI(host: "git", path: url)
    }

    /// Create a terminal workspace URI (an agent-driven PTY shell rooted at `rootPath`).
    public static func terminal(rootPath: String) -> WorkspaceURI {
        WorkspaceURI(host: "pk-terminal", path: rootPath)
    }
}
