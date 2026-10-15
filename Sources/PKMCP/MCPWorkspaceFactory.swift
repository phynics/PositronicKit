import PKContracts
import PositronicKit

/// A `WorkspaceFactory` that rebuilds MCP server connections from persisted workspace metadata.
///
/// Inject one into `PKRuntime/Configuration` (through `PKRuntime/RuntimeConfiguration`) so the
/// runtime can resolve an MCP Workspace created by
/// `WorkspaceCapability/createMCPWorkspace(_:for:)`. The factory holds no connection state; each
/// resolved reference gets its own MCP provider actor.
///
/// The runtime has a single workspace factory, so it also resolves the runtime's timeline and
/// agent-primary Workspaces. References that do not carry an MCP configuration are delegated to
/// `fallback`; pass the factory the runtime would otherwise use (for example the host's local
/// filesystem factory).
///
/// ```swift
/// let mcp = MCPWorkspaceFactory(
///     secretResolver: MCPDictionarySecretResolver([
///         "github-token": ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? "",
///     ]),
///     fallback: hostLocalWorkspaceFactory
/// )
/// let kit = PKRuntime(configuration: .init(
///     languageModel: model,
///     persistence: .inMemory(),
///     runtime: .init(workspaceCreator: mcp)
/// ))
/// ```
public struct MCPWorkspaceFactory: WorkspaceFactory {
    private let secretResolver: any MCPSecretResolver
    private let fallback: any WorkspaceFactory
    let transportFactory: MCPTransportFactory?

    /// Creates a factory that resolves referenced secrets through `secretResolver` and delegates
    /// non-MCP references to `fallback`.
    public init(
        secretResolver: any MCPSecretResolver,
        fallback: any WorkspaceFactory = NullWorkspaceCreator()
    ) {
        self.init(secretResolver: secretResolver, fallback: fallback, transportFactory: nil)
    }

    /// Test seam: a factory that builds transports through `transportFactory` instead of the
    /// platform transports.
    init(
        secretResolver: any MCPSecretResolver,
        fallback: any WorkspaceFactory,
        transportFactory: MCPTransportFactory?
    ) {
        self.secretResolver = secretResolver
        self.fallback = fallback
        self.transportFactory = transportFactory
    }

    public func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        guard reference.metadata?[MCPServerConfiguration.metadataKey] != nil else {
            return try fallback.create(from: reference)
        }
        let configuration = try reference.mcpServerConfiguration()
        return MCPWorkspaceProvider(
            reference: reference,
            configuration: configuration,
            secretResolver: secretResolver,
            transportFactory: transportFactory
        )
    }
}
