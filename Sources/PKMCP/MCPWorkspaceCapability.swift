import Foundation
import PKContracts
import PositronicKit

public extension WorkspaceCapability {
    /// Creates an MCP server Workspace and binds it to `timelineID`.
    ///
    /// The returned reference carries the secret-free server configuration in its metadata. The
    /// runtime resolves it with the `MCPWorkspaceFactory` injected into
    /// `PKRuntime/Configuration`. The Workspace uses the `.runtime` location so the runtime
    /// executes its tools in process through the ordinary `call_tool` dispatcher.
    ///
    /// ```swift
    /// let workspace = try await kit.workspaces.createMCPWorkspace(
    ///     MCPServerConfiguration(
    ///         name: "github",
    ///         transport: .stdio(executable: "/usr/local/bin/github-mcp", arguments: [], environment: [:])
    ///     ),
    ///     for: timelineID
    /// )
    /// ```
    func createMCPWorkspace(
        _ config: MCPServerConfiguration,
        for timelineID: UUID
    ) async throws -> WorkspaceReference {
        let metadata: [String: AnyCodable] = [
            MCPServerConfiguration.metadataKey: .dictionary(try config.persistedMetadata())
        ]
        return try await createAndAttach(
            uri: WorkspaceURI(host: "mcp", path: config.name),
            location: .runtime,
            to: timelineID,
            metadata: metadata
        )
    }

    /// Creates a session Workspace for a registered ``MCPServerProfile`` and binds it to
    /// `timelineID`.
    ///
    /// The returned reference carries only the profile identity in its metadata. The
    /// `MCPWorkspaceFactory` injected into `PKRuntime/Configuration` resolves that identity to the
    /// registered profile and rebuilds the live provider. Every Timeline that attaches the profile
    /// gets its own ordinary Workspace, so exclusive binding, per-Workspace FIFO serialization,
    /// and admission-time authority are unchanged. A `.pooled` profile shares one server
    /// connection across its session Workspaces; a `.perWorkspace` profile opens one connection per
    /// Workspace.
    ///
    /// ```swift
    /// let profile = MCPServerProfile(
    ///     id: "github",
    ///     configuration: githubConfiguration,
    ///     sessionScope: .pooled
    /// )
    /// let workspace = try await kit.workspaces.createMCPWorkspace(profile, for: timelineID)
    /// ```
    func createMCPWorkspace(
        _ profile: MCPServerProfile,
        for timelineID: UUID
    ) async throws -> WorkspaceReference {
        let metadata: [String: AnyCodable] = [
            MCPServerProfile.metadataKey: .string(profile.id)
        ]
        return try await createAndAttach(
            uri: WorkspaceURI(host: "mcp", path: profile.name),
            location: .runtime,
            to: timelineID,
            metadata: metadata
        )
    }
}
