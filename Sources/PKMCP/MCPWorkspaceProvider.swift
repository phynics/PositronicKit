import Foundation
import MCP
import PKContracts
import PositronicKit

/// Builds the SDK transport for a configuration. Internal so tests can inject an in-memory pair
/// without exposing the SDK's `Transport` in the public surface.
typealias MCPTransportFactory = @Sendable (MCPServerConfiguration) async throws -> any MCP.Transport

/// One session Workspace's view of an MCP server connection.
///
/// The provider owns workspace identity only. Connection lifecycle, tool caching, and reconnection
/// belong to the `MCPConnection` it delegates to. A `.perWorkspace` profile gives each provider a
/// private connection; a `.pooled` profile gives every provider for the profile the same shared
/// connection.
actor MCPWorkspaceProvider: WorkspaceToolProvider {
    nonisolated let reference: WorkspaceReference

    private let connection: MCPConnection

    /// Creates a provider over an existing connection.
    init(reference: WorkspaceReference, connection: MCPConnection) {
        self.reference = reference
        self.connection = connection
    }

    /// Creates a provider with a private connection, the `.perWorkspace` scope.
    init(
        reference: WorkspaceReference,
        configuration: MCPServerConfiguration,
        secretResolver: any MCPSecretResolver,
        transportFactory: MCPTransportFactory?
    ) {
        self.init(
            reference: reference,
            connection: MCPConnection(
                configuration: configuration,
                secretResolver: secretResolver,
                transportFactory: transportFactory
            )
        )
    }

    /// Whether the backing connection's most recent attempt succeeded. The provider is optimistic
    /// before the first connection so a lazily connected server is still offered to the model.
    var isHealthy: Bool {
        get async { await connection.isHealthy }
    }

    // MARK: - Tools

    func listTools() async throws -> [ToolReference] {
        try await connection.listTools()
    }

    func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult {
        try await connection.executeTool(id: id, parameters: parameters)
    }
}
