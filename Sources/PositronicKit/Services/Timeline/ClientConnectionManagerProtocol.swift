import PKShared
import Foundation

/// Transport hook for externally hosted workspaces.
///
/// PositronicKit does not ship a client/server runtime. Downstream hosts can implement this
/// protocol to bridge workspace references or tool execution onto another process or machine.
public protocol ExternalWorkspaceConnectionManagerProtocol: Actor, Sendable {
    /// Checks whether an external owner/host is currently reachable.
    func isConnected(clientId: UUID) async -> Bool

    /// Sends a request to an externally hosted workspace owner.
    /// - Parameters:
    ///   - method: The RPC method name.
    ///   - params: The parameters for the RPC method.
    ///   - expecting: The expected return type.
    ///   - clientId: The owner identifier to send the request to.
    /// - Returns: The result of the RPC call.
    func send<T: Codable & Sendable>(
        method: String,
        params: AnyCodable?,
        expecting: T.Type,
        to clientId: UUID
    ) async throws -> T
}

@available(*, deprecated, renamed: "ExternalWorkspaceConnectionManagerProtocol")
public typealias ClientConnectionManagerProtocol = ExternalWorkspaceConnectionManagerProtocol
