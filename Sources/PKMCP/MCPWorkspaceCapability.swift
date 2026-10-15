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
}
