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

    public init(
        name: String,
        instruction: String,
        schema: Schema,
        streaming: StreamingMode = .buffered
    ) {
        self.name = name
        self.instruction = instruction
        self.schema = schema
        self.streaming = streaming
    }
}

// MARK: - Validation Helpers

public extension SidecarDirective {
    /// The reserved JSON field name that cannot be used for directives.
    static let reservedFieldName = "response"

    /// Whether this directive's name is valid (non-empty and not reserved).
    var hasValidName: Bool {
        !name.isEmpty && name != Self.reservedFieldName
    }
}
