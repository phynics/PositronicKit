import Foundation
import struct JSONSchema.Schema
import PKShared

/// Pure composition of a combined structured-output request + instruction block
/// from a set of sidecar directives. No `ChatEngine` state; fully unit-testable.
///
/// Field order in the composed schema does **not** control model generation order —
/// `Schema`/`JSONValue` store object properties in an unordered `Dictionary`, and the
/// wire-serialization path (`JSONEncoder().encode(schema.schema)`) re-emits keys
/// independently of declaration order (see ticket SDC-7). Generation order is steered
/// only through `instructionBlock`'s prompt text, not schema structure.
///
/// The per-turn directive list (`instructionBlock`) rides with the user query — the last
/// prompt section — rather than system instructions, so the system prefix stays byte-stable
/// across turns for provider prompt-prefix caching and `PromptJournal` stable-prefix diffing.
/// An optional, name-free `mechanismPreamble` can be layered into system instructions for
/// consumers that want the model informed of the mechanism up front; the mechanism itself
/// does not depend on it.
public enum SidecarSchemaComposer {
    /// Semi-stable system-prompt preamble explaining the piggy-backed JSON mechanism in
    /// general terms. Contains NO directive names so it never changes with the directive
    /// set — safe in the cache-stable system section. The concrete per-turn directive list
    /// is delivered via `instructionBlock` alongside the user query. Optional: the
    /// mechanism works without it.
    public static let mechanismPreamble = """
    ## Piggy-backed output mechanism
    Some turns request auxiliary structured fields alongside your reply. On those turns the \
    final user message lists the requested fields and you must answer as a single JSON object \
    with your normal reply in the "response" field first and the auxiliary fields nested \
    inside the "sidecar_payload" object. \
    On turns without such a list, reply normally.
    """

    /// Combined schema: root keys `priority_sidecar_payload`, `response`, and
    /// `sidecar_payload`, omitting either sidecar container when no directive uses it.
    static func compose(directives: [SidecarDirective]) throws -> StructuredOutputRequest {
        try validate(directives)

        let priorityDirectives = directives.filter { $0.timing == .beforeResponse }
        let sidecarDirectives = directives.filter { $0.timing == .afterResponse }

        var rootProperties: [String: Any] = [:]
        var requiredRootKeys: [String] = []

        if !priorityDirectives.isEmpty {
            rootProperties[RootKey.prioritySidecarPayload] = try containerSchema(for: priorityDirectives)
            requiredRootKeys.append(RootKey.prioritySidecarPayload)
        }

        rootProperties[RootKey.response] = [
            "type": "string",
            "description": "The assistant's reply to the user. Markdown allowed.",
        ]
        requiredRootKeys.append(RootKey.response)

        if !sidecarDirectives.isEmpty {
            rootProperties[RootKey.sidecarPayload] = try containerSchema(for: sidecarDirectives)
            requiredRootKeys.append(RootKey.sidecarPayload)
        }

        let rawSchema: [String: Any] = [
            "type": "object",
            "properties": rootProperties,
            "required": requiredRootKeys,
            "additionalProperties": false,
        ]

        let data = try JSONSerialization.data(withJSONObject: rawSchema)
        let schema = try Schema(instance: String(decoding: data, as: UTF8.self))

        return .jsonSchema(StructuredOutputSchema(
            name: "sidecar_turn",
            description: "User-visible response plus piggy-backed auxiliary fields.",
            schema: schema,
            strict: true
        ))
    }

    /// Instruction text rendered with the final user-query prompt section. This is the only
    /// mechanism that steers the model to produce `response` ahead of the nested
    /// `sidecar_payload` object (see the type-level note on schema field order).
    public static func instructionBlock(directives: [SidecarDirective]) -> String {
        let priorityDirectives = directives.filter { $0.timing == .beforeResponse }
        let sidecarDirectives = directives.filter { $0.timing == .afterResponse }
        var lines: [String] = [
            "",
            "## Piggy-backed fields",
            "Reply as a single JSON object.",
        ]

        if !priorityDirectives.isEmpty {
            lines.append("Before your reply, produce these fields in the \"priority_sidecar_payload\" object:")
            for directive in priorityDirectives {
                lines.append("- \"\(directive.name)\": \(directive.instruction)")
            }
        }

        lines.append("Put your normal reply to the user in the \"response\" field.")

        if !sidecarDirectives.isEmpty {
            lines.append("After your reply, produce these fields in the \"sidecar_payload\" object:")
            for directive in sidecarDirectives {
                lines.append("- \"\(directive.name)\": \(directive.instruction)")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func validate(_ directives: [SidecarDirective]) throws {
        for directive in directives where !directive.hasValidName {
            throw SidecarError.reservedOrInvalidName(directive.name)
        }
        let reservedRootKeys = SidecarDirective.reservedFieldNames
        if let reserved = directives.first(where: { reservedRootKeys.contains($0.name) }) {
            throw SidecarError.reservedOrInvalidName(reserved.name)
        }
        let names = directives.map(\.name)
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $1.count > 1 }.keys
        if !duplicates.isEmpty {
            throw SidecarError.duplicateDirectiveNames(duplicates.sorted())
        }
    }

    private static func rawJSONObject(for schema: Schema) throws -> Any {
        let data = try JSONEncoder().encode(schema)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func containerSchema(for directives: [SidecarDirective]) throws -> [String: Any] {
        var properties: [String: Any] = [:]
        for directive in directives {
            properties[directive.name] = try rawJSONObject(for: directive.schema)
        }

        return [
            "type": "object",
            "properties": properties,
            "required": directives.map(\.name),
            "additionalProperties": false,
        ]
    }

    private typealias RootKey = SidecarDirective.RootKey
}
