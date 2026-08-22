import Foundation

/// The authority path that admitted a Turn.
public enum TurnExecutionKind: String, Codable, Equatable, Hashable, Sendable {
    /// The Thread supplied its attached Agent and the runtime assembled managed context.
    case agentManaged
    /// The caller supplied the direct context on a detached Thread.
    case direct
}

/// A caller-selected contributor for a direct Turn.
///
/// Direct Turns do not inherit Agent identity or Agent context. The contributor label is opaque
/// to the runtime and lets a caller select which explicit context contributors participate.
public struct TurnContributor: Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// A conventional host-owned contributor label.
    public static let host = Self("host")
}

/// Explicit caller-owned context required for direct Turn execution.
public struct DirectTurnContext: Codable, Equatable, Hashable, Sendable {
    /// The complete system prompt for this direct Turn. An empty string is intentional and is
    /// distinct from omitting the context entirely.
    public let systemInstructions: String
    /// The contributor set selected by the caller for this direct Turn.
    public let contributors: [TurnContributor]

    public init(systemInstructions: String, contributors: [TurnContributor]) {
        self.systemInstructions = systemInstructions
        self.contributors = contributors
    }

    /// Convenience initializer for the common single-contributor direct Turn.
    public init(systemInstructions: String, contributor: TurnContributor) {
        self.init(systemInstructions: systemInstructions, contributors: [contributor])
    }

    /// String-labelled convenience initializer for hosts that resolve contributors dynamically.
    public init(systemInstructions: String, contributor: String) {
        self.init(systemInstructions: systemInstructions, contributor: TurnContributor(contributor))
    }

    /// Alias using the prompt vocabulary used by downstream consumers.
    public var systemPrompt: String { systemInstructions }
}
