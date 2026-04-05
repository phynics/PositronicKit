import ErrorKit
import Foundation
import MonadShared

/// Defines the capabilities and behaviors of a workspace
public protocol WorkspaceProtocol: Sendable {
    /// The unique identifier of the workspace
    var id: UUID { get }

    /// The metadata reference for this workspace
    var reference: WorkspaceReference { get }

    /// List all available tools in this workspace
    func listTools() async throws -> [ToolReference]

    /// Execute a specific tool in this workspace
    func executeTool(id: String, parameters: [String: AnyCodable]) async throws -> ToolResult

    /// Read a file from the workspace
    func readFile(path: String) async throws -> String

    /// Write to a file in the workspace
    func writeFile(path: String, content: String) async throws

    /// List files in the workspace (optionally recursively)
    func listFiles(path: String) async throws -> [String]

    /// Delete a file in the workspace
    func deleteFile(path: String) async throws

    /// Get the health/status of the workspace connection
    func healthCheck() async -> Bool
}

public enum WorkspaceError: MonadError, Sendable {
    case invalidWorkspaceType
    case accessDenied
    case toolExecutionNotSupported
    case workspaceNotFound
    case connectionFailed

    public var errorDomain: String { MonadErrorDomain.workspace }

    public var errorCode: Int {
        switch self {
        case .invalidWorkspaceType: return 3001
        case .accessDenied: return 3002
        case .toolExecutionNotSupported: return 3003
        case .workspaceNotFound: return 3004
        case .connectionFailed: return 3005
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

/// Abstracts workspace instantiation to allow MonadCore to be decoupled from concrete implementations
public protocol WorkspaceCreating: Sendable {
    func create(
        from reference: WorkspaceReference,
        connectionManager: (any ClientConnectionManagerProtocol)?
    ) throws -> any WorkspaceProtocol
}

/// A no-op workspace creator used when no concrete factory is available (e.g. in unit tests).
/// Always throws `WorkspaceError.workspaceNotFound`.
public struct NullWorkspaceCreator: WorkspaceCreating {
    public init() {}
    public func create(
        from reference: WorkspaceReference,
        connectionManager: (any ClientConnectionManagerProtocol)?
    ) throws -> any WorkspaceProtocol {
        throw WorkspaceError.workspaceNotFound
    }
}
