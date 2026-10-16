import PKContracts
import PositronicKit

/// A `WorkspaceFactory` that rebuilds MCP server connections from persisted workspace metadata.
///
/// Inject one into `PKRuntime/Configuration` (through `PKRuntime/RuntimeConfiguration`) so the
/// runtime can resolve an MCP Workspace created by `WorkspaceCapability/createMCPWorkspace(_:for:)`.
/// The factory holds no connection state itself; each resolved reference gets a provider, and a
/// `.pooled` profile shares one `MCPConnection` across all of its session Workspaces.
///
/// The runtime has a single workspace factory, so it also resolves the runtime's timeline and
/// agent-primary Workspaces. References that do not carry an MCP configuration or profile are
/// delegated to `fallback`; pass the factory the runtime would otherwise use (for example the
/// host's local filesystem factory).
///
/// ```swift
/// let mcp = MCPWorkspaceFactory(
///     secretResolver: MCPDictionarySecretResolver([
///         "github-token": ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? "",
///     ]),
///     profiles: [
///         MCPServerProfile(
///             id: "github",
///             configuration: githubConfiguration,
///             sessionScope: .pooled
///         ),
///     ],
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
    private let profiles: [String: MCPServerProfile]
    private let pooledConnections: [String: MCPConnection]

    /// Creates a factory that resolves referenced secrets through `secretResolver`, serves the
    /// registered `profiles`, and delegates non-MCP references to `fallback`.
    ///
    /// Register each reusable server once here, then attach it to any number of Timelines with
    /// `WorkspaceCapability/createMCPWorkspace(_:for:)`. A `.pooled` profile creates its shared
    /// connection eagerly; it connects lazily on first use.
    public init(
        secretResolver: any MCPSecretResolver,
        profiles: [MCPServerProfile] = [],
        fallback: any WorkspaceFactory = NullWorkspaceCreator()
    ) {
        self.init(
            secretResolver: secretResolver,
            profiles: profiles,
            fallback: fallback,
            transportFactory: nil
        )
    }

    /// Test seam: a factory that builds transports through `transportFactory` instead of the
    /// platform transports.
    init(
        secretResolver: any MCPSecretResolver,
        profiles: [MCPServerProfile] = [],
        fallback: any WorkspaceFactory,
        transportFactory: MCPTransportFactory?
    ) {
        var registered: [String: MCPServerProfile] = [:]
        var pooled: [String: MCPConnection] = [:]
        for profile in profiles {
            registered[profile.id] = profile
            if profile.sessionScope == .pooled {
                pooled[profile.id] = MCPConnection(
                    configuration: profile.configuration,
                    secretResolver: secretResolver,
                    transportFactory: transportFactory
                )
            }
        }
        self.secretResolver = secretResolver
        self.fallback = fallback
        self.transportFactory = transportFactory
        self.profiles = registered
        self.pooledConnections = pooled
    }

    public func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        if let profileID = reference.mcpServerProfileID() {
            guard let profile = profiles[profileID] else {
                throw MCPWorkspaceError.unknownProfile(profileID)
            }
            if let shared = pooledConnections[profileID] {
                return MCPWorkspaceProvider(reference: reference, connection: shared)
            }
            return MCPWorkspaceProvider(
                reference: reference,
                configuration: profile.configuration,
                secretResolver: secretResolver,
                transportFactory: transportFactory
            )
        }

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
