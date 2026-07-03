import Foundation
import struct JSONSchema.Schema
import PKShared

/// Pure composition of a combined structured-output request + instruction block
/// from a set of sidecar directives. No `ChatEngine` state; fully unit-testable.
///
/// Field order in the composed schema does **not** control model generation order —
/// `Schema`/`JSONValue` store object properties in an unordered `Dictionary`, and the
/// wire-serialization path (`JSONEncoder().encode(schema.schema)`) re-emits keys
/// alphabetically regardless of declaration order (see ticket SDC-7). Generation order
/// is steered only through `instructionBlock`'s prompt text, not schema structure.
enum SidecarSchemaComposer {
    /// Combined schema: `response` (string) plus one property per directive, all
    /// required, strict, no additional properties.
    static func compose(directives: [SidecarDirective]) throws -> StructuredOutputRequest {
        try validate(directives)

        var properties: [String: Any] = [
            "response": [
                "type": "string",
                "description": "The assistant's reply to the user. Markdown allowed.",
            ],
        ]
        for directive in directives {
            properties[directive.name] = try rawJSONObject(for: directive.schema)
        }

        let rawSchema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": [SidecarDirective.reservedFieldName] + directives.map(\.name),
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

    /// Instruction text appended to the turn's system instructions. This is the only
    /// mechanism that steers the model to produce `response` ahead of directive
    /// fields (see the type-level note on schema field order).
    static func instructionBlock(directives: [SidecarDirective]) -> String {
        var lines: [String] = [
            "",
            "## Piggy-backed fields",
            "Reply as a single JSON object. Put your normal reply to the user in the \"response\" field first.",
            "Additionally produce these fields from the same conversation context:",
        ]
        for directive in directives {
            lines.append("- \"\(directive.name)\": \(directive.instruction)")
        }
        return lines.joined(separator: "\n")
    }

    static func validate(_ directives: [SidecarDirective]) throws {
        for directive in directives where !directive.hasValidName {
            throw SidecarError.reservedOrInvalidName(directive.name)
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
}
