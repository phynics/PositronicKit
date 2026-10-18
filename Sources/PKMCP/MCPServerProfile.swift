import Foundation
import PKContracts
import PositronicKit

/// How a profile's transport is shared across the session Workspaces that use it.
public enum MCPSessionScope: String, Codable, Sendable, Hashable, CaseIterable {
    /// Every session Workspace opens its own connection to the server.
    ///
    /// Use this for servers that hold per-session state (for example a browser session or a REPL),
    /// where isolation between Timelines is the point.
    case perWorkspace
    /// Every session Workspace for the profile shares one connection to the server.
    ///
    /// Use this for stateless tool catalogs, where per-Timeline isolation is wasted. The runtime
    /// still serializes execution per Workspace; the shared connection also serves those Workspaces
    /// concurrently, so a stateful server must use `.perWorkspace`.
    case pooled
}

/// A reusable MCP server configuration registered once with ``MCPWorkspaceFactory``.
///
/// A profile separates the reusable server configuration from the session Workspace. Register it
/// with `MCPWorkspaceFactory`, then attach it to as many Timelines as needed with
/// `WorkspaceCapability/createMCPWorkspace(_:for:)`. Each attached Workspace is an ordinary
/// Workspace: exclusive binding, per-Workspace FIFO serialization, and admission-time authority
/// are unchanged.
///
/// A persisted `WorkspaceReference` stores only the profile identity, never the configuration.
/// That keeps a shared profile from duplicating its server configuration on every session
/// reference and from re-persisting a secret reference for each Timeline. The factory resolves the
/// identity against the profiles it was created with; an unknown identity is an error.
public struct MCPServerProfile: Codable, Sendable, Hashable {
    /// The `WorkspaceReference.metadata` key under which the profile identity is persisted.
    public static let metadataKey = "mcp.server.profile"

    /// Host-chosen identity, unique within one factory registration.
    public let id: String
    /// The reusable server configuration.
    public var configuration: MCPServerConfiguration
    /// Whether the session Workspaces share one connection.
    public var sessionScope: MCPSessionScope

    /// Creates a profile with an explicit identity.
    public init(
        id: String,
        configuration: MCPServerConfiguration,
        sessionScope: MCPSessionScope = .perWorkspace
    ) {
        self.id = id
        self.configuration = configuration
        self.sessionScope = sessionScope
    }

    /// Creates a profile whose identity is the configuration's server name.
    public init(
        configuration: MCPServerConfiguration,
        sessionScope: MCPSessionScope = .perWorkspace
    ) {
        self.init(
            id: configuration.name,
            configuration: configuration,
            sessionScope: sessionScope
        )
    }

    /// The server name from the configuration. Used as the session Workspace's URI path.
    public var name: String { configuration.name }
}

extension WorkspaceReference {
    /// The MCP server profile identity persisted on this reference, if any.
    func mcpServerProfileID() -> String? {
        guard case let .string(id)? = metadata?[MCPServerProfile.metadataKey] else {
            return nil
        }
        return id
    }
}
