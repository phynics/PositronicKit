import ErrorKit
import Foundation
import PKContracts
import PKUtilities

/// A live adapter for a persisted `WorkspaceReference`.
///
/// The reference owns workspace identity and metadata. A provider supplies only the operations
/// available while that workspace is active. Providers may be remote, local, database-backed, or
/// otherwise host-defined; filesystem and tool operations are separate capabilities below.
public protocol WorkspaceProvider: Sendable {
    /// The persisted identity and metadata represented by this provider.
    var reference: WorkspaceReference { get }

    /// Returns whether the provider can currently reach its backing workspace.
    func healthCheck() async -> Bool
}

public extension WorkspaceProvider {
    /// Convenience identity derived from the authoritative reference.
    var id: UUID { reference.id }
}

/// Optional capability for providers that expose executable tools.
public protocol WorkspaceToolProvider: WorkspaceProvider {
    /// Lists the tools currently exposed by the workspace.
    func listTools() async throws -> [ToolReference]

    /// Executes one workspace-owned tool.
    func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult
}

/// Optional capability for providers that expose workspace files.
public protocol WorkspaceFileProvider: WorkspaceProvider {
    /// Reads a file from the workspace.
    func readFile(path: String) async throws -> String

    /// Lists files in the workspace, optionally recursively.
    func listFiles(path: String) async throws -> [String]

    /// Writes a file in the workspace.
    func writeFile(path: String, content: String) async throws

    /// Deletes a file from the workspace.
    func deleteFile(path: String) async throws
}

public enum WorkspaceError: PKError, Sendable {
    case invalidWorkspaceType
    case accessDenied
    case toolExecutionNotSupported
    case workspaceNotFound
    case connectionFailed

    public var errorDomain: String { PKErrorDomain.workspace }

    public var errorCode: Int {
        switch self {
        case .invalidWorkspaceType: return 3001
        case .accessDenied: return 3002
        case .toolExecutionNotSupported: return 3003
        case .workspaceNotFound: return 3004
        case .connectionFailed: return 3005
        }
    }

    /// `accessDenied` represents a blocked/disallowed condition — the caller does
    /// not have permission to access the workspace, so execution is refused by
    /// an access gate.
    public var isBlocked: Bool {
        switch self {
        case .accessDenied: return true
        default: return false
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .invalidWorkspaceType:
            return "The workspace configuration is invalid."
        case .accessDenied:
            return "You do not have permission to access this workspace."
        case .toolExecutionNotSupported:
            return "This workspace does not support tool execution."
        case .workspaceNotFound:
            return "The requested workspace could not be found."
        case .connectionFailed:
            return "Failed to connect to the workspace. Please check the network connection."
        }
    }
}

/// Abstracts live workspace-provider instantiation so the runtime stays decoupled from concrete
/// workspace backends.
public protocol WorkspaceFactory: Sendable {
    func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider
}

/// A no-op workspace creator used when no concrete provider is available (e.g. in unit tests).
/// Always throws `WorkspaceError.workspaceNotFound`.
public struct NullWorkspaceCreator: WorkspaceFactory {
    public init() {}
    public func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        throw WorkspaceError.workspaceNotFound
    }
}
