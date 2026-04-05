import MonadShared
import Foundation

/// Defines the contract for managing client connections and sending RPC requests.
public protocol ClientConnectionManagerProtocol: Actor, Sendable {
    /// Checks if a client with the given ID is currently connected.
    func isConnected(clientId: UUID) async -> Bool

    /// Sends an RPC request to a connected client.
    /// - Parameters:
    ///   - method: The RPC method name.
    ///   - params: The parameters for the RPC method.
    ///   - expecting: The expected return type.
    ///   - clientId: The ID of the client to send the request to.
    /// - Returns: The result of the RPC call.
    func send<T: Codable & Sendable>(
        method: String,
        params: AnyCodable?,
        expecting: T.Type,
        to clientId: UUID
    ) async throws -> T
}
