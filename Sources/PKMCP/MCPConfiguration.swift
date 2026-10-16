import Foundation
import PKContracts

/// Whether an MCP tool call requires the runtime's approval gate.
///
/// MCP tool annotations are untrusted hints from the server, so a host can override them.
public enum MCPPermissionPolicy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Require permission unless the tool's `readOnlyHint` annotation is exactly `true`.
    ///
    /// This is the default. An unannotated tool is treated as requiring permission.
    case annotations
    /// Always require permission, even for a tool the server marks read-only.
    case always
    /// Never require permission for this server's tools.
    case never
}

/// A host-resolved secret identifier.
///
/// The referenced value is never persisted in a `WorkspaceReference`; a host resolves it at
/// connect time through an `MCPSecretResolver`.
public struct MCPSecretReference: Codable, Sendable, Hashable, CustomStringConvertible {
    /// The host-chosen key for the secret.
    public let key: String

    public var description: String { key }

    public init(key: String) {
        self.key = key
    }

    public init(_ key: String) {
        self.key = key
    }
}

/// Resolves a host-held secret for an MCP server connection.
///
/// The runtime calls this at connect time. Implementations must not persist the resolved value
/// into a `WorkspaceReference`.
public protocol MCPSecretResolver: Sendable {
    /// Resolves the value for `reference`.
    ///
    /// Throw `MCPWorkspaceError/secretResolutionFailed(key:)` when the key is unknown.
    func resolveSecret(_ reference: MCPSecretReference) async throws -> String
}

/// A value passed to an MCP server's transport as either a literal or a resolved secret.
///
/// A `.secret` value persists only its reference, so a serialized workspace reference never
/// contains secret material. String literals are accepted so call sites can spell non-secret
/// values (for example `PATH`) directly.
public enum MCPSecretValue: Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    /// A non-secret literal value.
    case value(String)
    /// A reference resolved by the host at connect time.
    case secret(MCPSecretReference)

    public init(stringLiteral value: String) {
        self = .value(value)
    }

    /// The literal value, if this is not a secret reference.
    public var literalValue: String? {
        guard case let .value(value) = self else { return nil }
        return value
    }
}

/// A resolver backed by an in-memory dictionary.
///
/// Useful for host bootstrap and tests. The dictionary is captured by value and never written to
/// a workspace reference.
public struct MCPDictionarySecretResolver: MCPSecretResolver {
    private let secrets: [String: String]

    public init(_ secrets: [String: String]) {
        self.secrets = secrets
    }

    public func resolveSecret(_ reference: MCPSecretReference) async throws -> String {
        guard let value = secrets[reference.key] else {
            throw MCPWorkspaceError.secretResolutionFailed(key: reference.key)
        }
        return value
    }
}

/// The persisted, secret-free description of one MCP server connection.
///
/// One configuration maps to one Workspace. The configuration is stored on the workspace
/// reference and rebuilt by `MCPWorkspaceFactory` when the Workspace is resolved.
public struct MCPServerConfiguration: Codable, Sendable, Hashable {
    /// How the client reaches the MCP server.
    public enum Transport: Codable, Sendable, Hashable {
        /// Spawn a local server process and speak MCP over its standard streams.
        ///
        /// Available on macOS and Linux. On iOS the runtime reports
        /// `MCPWorkspaceError/unsupportedTransport(_:)`.
        case stdio(executable: String, arguments: [String], environment: [String: MCPSecretValue])
        /// Connect to a Streamable HTTP MCP endpoint.
        case streamableHTTP(url: URL, headers: [String: MCPSecretValue])
    }

    /// The Workspace name and the `mcp:<name>` URI path.
    public var name: String
    /// How the client reaches the server.
    public var transport: Transport
    /// Whether tool calls require approval.
    public var permission: MCPPermissionPolicy
    /// Optional per-call timeout. When `nil`, only the runtime's tool timeout applies.
    public var callTimeout: Duration?

    public init(
        name: String,
        transport: Transport,
        permission: MCPPermissionPolicy = .annotations,
        callTimeout: Duration? = nil
    ) {
        self.name = name
        self.transport = transport
        self.permission = permission
        self.callTimeout = callTimeout
    }
}

// MARK: - Persistence

extension MCPServerConfiguration {
    /// The `WorkspaceReference.metadata` key under which the configuration is persisted.
    static let metadataKey = "mcp.server.configuration"

    /// Encodes this configuration as the metadata dictionary stored on a workspace reference.
    func persistedMetadata() throws -> [String: AnyCodable] {
        let data = try JSONEncoder().encode(self)
        let encoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        guard case let .dictionary(dictionary) = encoded else {
            throw MCPWorkspaceError.invalidConfiguration("configuration did not encode as an object")
        }
        return dictionary
    }

    /// Decodes a configuration from a workspace reference's metadata.
    ///
    /// Throws `MCPWorkspaceError/invalidConfiguration(_:)` when the metadata is missing or
    /// malformed.
    static func fromPersistedMetadata(_ metadata: [String: AnyCodable]?) throws -> MCPServerConfiguration {
        guard let encoded = metadata?[metadataKey] else {
            throw MCPWorkspaceError.invalidConfiguration("workspace reference has no MCP configuration")
        }
        guard case let .dictionary(dictionary) = encoded else {
            throw MCPWorkspaceError.invalidConfiguration("MCP configuration metadata is not an object")
        }
        let data = try JSONEncoder().encode(AnyCodable.dictionary(dictionary))
        return try JSONDecoder().decode(MCPServerConfiguration.self, from: data)
    }
}

extension WorkspaceReference {
    /// The MCP server configuration persisted on this reference.
    func mcpServerConfiguration() throws -> MCPServerConfiguration {
        try MCPServerConfiguration.fromPersistedMetadata(metadata)
    }
}

// MARK: - Errors

/// Stable failure identity for the MCP adapter.
public enum MCPWorkspaceError: PKError, Sendable, Equatable {
    /// The workspace reference did not carry a usable configuration.
    case invalidConfiguration(String)
    /// A session Workspace referenced a profile the factory does not have registered.
    case unknownProfile(String)
    /// The configuration requested a transport the current platform cannot provide.
    case unsupportedTransport(String)
    /// The host did not supply a value for a referenced secret.
    case secretResolutionFailed(key: String)
    /// The client could not connect or lost its connection.
    case connectionFailed(String)
    /// A tool call exceeded its configured timeout.
    case callTimedOut(tool: String, seconds: Double)
    /// The server did not expose the tools capability.
    case toolsUnavailable(String)
    /// The MCP server returned a JSON-RPC error.
    case serverError(String)

    public var errorDomain: String { PKErrorDomain.mcp }

    public var errorCode: Int {
        switch self {
        case .invalidConfiguration: return 4001
        case .unsupportedTransport: return 4002
        case .secretResolutionFailed: return 4003
        case .connectionFailed: return 4004
        case .callTimedOut: return 4005
        case .toolsUnavailable: return 4006
        case .serverError: return 4007
        case .unknownProfile: return 4008
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .invalidConfiguration(detail):
            return "The MCP server configuration is invalid: \(detail)."
        case let .unknownProfile(id):
            return "The MCP server profile '\(id)' is not registered with this factory."
        case let .unsupportedTransport(detail):
            return "This MCP transport is not available: \(detail)."
        case let .secretResolutionFailed(key):
            return "The MCP server secret '\(key)' could not be resolved."
        case let .connectionFailed(detail):
            return "The MCP server is unavailable: \(detail)."
        case let .callTimedOut(tool, seconds):
            return "The MCP tool '\(tool)' timed out after \(seconds) seconds."
        case let .toolsUnavailable(detail):
            return "The MCP server does not expose tools: \(detail)."
        case let .serverError(detail):
            return "The MCP server reported an error: \(detail)."
        }
    }
}
