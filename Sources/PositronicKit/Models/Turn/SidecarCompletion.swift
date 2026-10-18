import Foundation

/// Identified sidecar results committed for a completed round-trip.
public struct SidecarCompletion: Sendable, Equatable, Codable {
    public let identity: TurnIdentity
    public let results: [SidecarResult]

    public init(identity: TurnIdentity, results: [SidecarResult]) {
        self.identity = identity
        self.results = results
    }
}
