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
        ///
        /// The value is the per-directive payload value extracted from
        /// `sidecar_payload[directive.name]` — i.e. the JSON value associated with the
        /// directive's key, not a wrapper object. Its `AnyCodable` case depends on the
        /// directive's schema shape:
        /// - A leaf scalar schema (e.g. `JSONString().definition()`) yields `.string` / `.number`.
        /// - An object schema (e.g. from `@Schemable` on a payload struct) yields `.dictionary`.
        ///
        /// Consumers must decode through the directive's payload type (or inspect the
        /// `AnyCodable` case tag), not assume `AnyCodable.asString` — that accessor returns
        /// `nil` for `.dictionary` values (see `AnyCodable.swift:38-41`). Round-tripping
        /// through `Codable` preserves the case tag. (PKTEST-1)
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
