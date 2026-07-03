import Foundation

/// Streaming update for a single sidecar directive field.
public struct SidecarDelta: Sendable, Equatable, Codable {
    public let name: String
    /// Best-effort partial text for `.incremental` directives; complete text on the final delta.
    public let partialText: String
    public let isFinal: Bool

    public init(name: String, partialText: String, isFinal: Bool) {
        self.name = name
        self.partialText = partialText
        self.isFinal = isFinal
    }
}

/// Final outcome of one sidecar directive for the turn.
public struct SidecarResult: Sendable, Equatable, Codable {
    public enum Outcome: Sendable, Equatable, Codable {
        /// Parsed value for the field.
        case value(AnyCodable)
        /// The model explicitly returned `null` — a valid non-answer, not an error.
        case declined
        /// The field never completed / failed to parse. Best-effort partial text, if any,
        /// is carried in `SidecarDelta`s already emitted.
        case failed(reason: String)
    }

    public let name: String
    public let outcome: Outcome

    public init(name: String, outcome: Outcome) {
        self.name = name
        self.outcome = outcome
    }
}
