import Foundation
import struct JSONSchema.Schema

/// A directive requesting an auxiliary structured output field alongside the main chat response.
///
/// Sidecar directives let the LLM produce multiple outputs (summary, title, markers, etc.)
/// in a single request. The response field streams normally; directive results are extracted
/// through incremental JSON parsing and emitted as `ChatEvent` cases.
///
/// Per the spec (`workflow/Yakamoz/specs/2026-07-03-piggybacked-requests-design.md`),
/// the mechanism lives here in `PositronicKit`; concrete directives (title, summary, tone)
/// and their scheduling policy live in consumer apps (Yakamoz).
public struct SidecarDirective: Sendable, Equatable, Codable {
    /// Determines how a directive's value is delivered to consumers.
    public enum StreamingMode: Sendable, Equatable, Codable {
        /// Deliver the complete value once the field is fully parsed.
        case buffered
        /// Deliver partial values as they are generated (useful for long fields like summaries).
        case incremental
    }

    /// Determines whether a directive is emitted before or after the user-visible response.
    public enum Timing: Sendable, Equatable, Codable {
        /// Generated before `response` for gating or routing decisions.
        case beforeResponse
        /// Generated after `response` for auxiliary metadata like titles or summaries.
        case afterResponse
    }

    /// The JSON field name for this directive. Must be unique per turn and not "response"
    /// (reserved for the main assistant response).
    public let name: String

    /// The prompt text describing what this directive should produce. Rendered into the
    /// final user-query prompt section via `SidecarSchemaComposer.instructionBlock`,
    /// keeping the system prompt stable for provider prompt-prefix caching.
    public let instruction: String

    /// JSON Schema for this directive's field, applied at schema composition time.
    public let schema: Schema

    /// Delivery mode: whether the field is buffered until complete or streamed incrementally.
    public let streaming: StreamingMode

    /// Whether this directive belongs to the pre-response or post-response sidecar container.
    public let timing: Timing

    public init(
        name: String,
        instruction: String,
        schema: Schema,
        streaming: StreamingMode = .buffered,
        timing: Timing = .afterResponse
    ) {
        self.name = name
        self.instruction = instruction
        self.schema = schema
        self.streaming = streaming
        self.timing = timing
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case instruction
        case schema
        case streaming
        case timing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        instruction = try container.decode(String.self, forKey: .instruction)
        schema = try container.decode(Schema.self, forKey: .schema)
        streaming = try container.decode(StreamingMode.self, forKey: .streaming)
        timing = try container.decodeIfPresent(Timing.self, forKey: .timing) ?? .afterResponse
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(instruction, forKey: .instruction)
        try container.encode(schema, forKey: .schema)
        try container.encode(streaming, forKey: .streaming)
        try container.encode(timing, forKey: .timing)
    }
}

// MARK: - Validation Helpers

public extension SidecarDirective {
    /// Fixed root-level wire keys used by the sidecar transport. `SidecarSchemaComposer`
    /// composes the schema around these keys and `SidecarStreamExtractor` reads them back;
    /// both consume this single definition so the wire format can't drift between them.
    enum RootKey {
        public static let prioritySidecarPayload = "priority_sidecar_payload"
        public static let response = SidecarDirective.reservedFieldName
        public static let sidecarPayload = "sidecar_payload"
    }

    /// The reserved JSON field name that cannot be used for directives.
    static let reservedFieldName = "response"

    /// Reserved structural container names used by the sidecar transport.
    static let reservedContainerFieldNames: Set<String> = [
        RootKey.prioritySidecarPayload,
        RootKey.sidecarPayload,
    ]

    /// Whether this directive's name is valid (non-empty and not reserved).
    var hasValidName: Bool {
        !name.isEmpty && !Self.reservedFieldNames.contains(name)
    }

    static var reservedFieldNames: Set<String> {
        reservedContainerFieldNames.union([reservedFieldName])
    }
}
