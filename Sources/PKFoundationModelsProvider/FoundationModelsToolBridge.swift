import Foundation
import struct JSONSchema.Schema
import PKShared

#if canImport(FoundationModels)
    import FoundationModels

    /// Bridges a PositronicKit `AnyTool` to the framework's typed `Tool` protocol (PKPOST-003).
    ///
    /// `FoundationModels.Tool.Arguments` must conform to `ConvertibleFromGeneratedContent`;
    /// `GeneratedContent` itself satisfies that (confirmed against the SDK), so this bridge uses
    /// `GeneratedContent` as `Arguments` and decodes named properties out of it via
    /// `GeneratedContent.value(_:forProperty:)`, rather than requiring a `@Generable` type per
    /// tool (PositronicKit tools are schema-described at runtime via `parametersSchema`, not
    /// known Swift types at compile time).
    @available(macOS 26.0, *)
    struct PKBridgedFMTool: FoundationModels.Tool {
        let wrapped: AnyTool

        var name: String {
            wrapped.id
        }

        var description: String {
            wrapped.description
        }

        var parameters: GenerationSchema {
            FoundationModelsSchemaBridge.generationSchema(for: wrapped)
        }

        func call(arguments: GeneratedContent) async throws -> String {
            let parameters = FoundationModelsSchemaBridge.decodeParameters(
                arguments,
                schema: wrapped.parametersSchema
            )
            let result = try await wrapped.execute(parameters: parameters)
            if result.success {
                return result.output
            }
            // Tool failures are reported back to the model as textual output (matching how the
            // HTTP-family adapters surface tool errors as `tool`-role message content) rather
            // than thrown, since a thrown error here surfaces as `ToolCallError` and aborts the
            // turn instead of letting the model retry/adjust its arguments.
            return "Error: \(result.error ?? "tool execution failed")"
        }
    }

    /// Converts between PositronicKit's typed `Schema` `parametersSchema` /
    /// `AnyCodable` argument values and the framework's `GenerationSchema`/`GeneratedContent`.
    /// Isolated in its own type so the conversion logic (a finite, testable JSON-Schema subset —
    /// object-of-primitives, matching what PositronicKit tools currently declare) is easy to
    /// extend without touching the `Tool` conformance itself.
    @available(macOS 26.0, *)
    enum FoundationModelsSchemaBridge {
        static func generationSchema(for tool: AnyTool) -> GenerationSchema {
            // parametersSchema is the typed Schema; introspect its wire form for properties.
            let schemaDict = tool.parametersSchema.asDictionary
            let properties = schemaDict["properties"]?.asDictionary ?? [:]
            let required = Set(
                (schemaDict["required"]?.asArray ?? []).compactMap(\.asString)
            )

            let dynamicProperties: [DynamicGenerationSchema.Property] = properties.map { key, value in
                let dict = value.asDictionary ?? [:]
                let description = dict["description"]?.asString
                let type = dict["type"]?.asString ?? "string"
                return DynamicGenerationSchema.Property(
                    name: key,
                    description: description,
                    schema: dynamicSchema(forJSONType: type),
                    isOptional: !required.contains(key)
                )
            }

            let root = DynamicGenerationSchema(
                name: "\(tool.id)_arguments",
                description: tool.description,
                properties: dynamicProperties
            )
            guard let schema = try? GenerationSchema(root: root, dependencies: []) else {
                // Falls back to an empty-object schema rather than crashing; a tool whose
                // schema fails to bridge is still registered (so the model sees it exists) but
                // effectively takes no arguments until the schema is fixed upstream.
                let empty = DynamicGenerationSchema(name: "\(tool.id)_arguments", properties: [])
                return (try? GenerationSchema(root: empty, dependencies: [])) ?? GenerationSchema(
                    type: GeneratedContent.self,
                    description: nil,
                    properties: []
                )
            }
            return schema
        }

        private static func dynamicSchema(forJSONType type: String) -> DynamicGenerationSchema {
            switch type {
            case "integer":
                return DynamicGenerationSchema(type: Int.self)
            case "number":
                return DynamicGenerationSchema(type: Double.self)
            case "boolean":
                return DynamicGenerationSchema(type: Bool.self)
            default:
                // "string", "array", "object", and anything unrecognized: fall back to string.
                // Arbitrary nested array/object argument schemas are a documented gap (README
                // support matrix) — PositronicKit's built-in tools are all flat objects of
                // primitives today, so this covers the actual call sites.
                return DynamicGenerationSchema(type: String.self)
            }
        }

        /// Decodes a tool's `GeneratedContent` arguments back into the `[String: AnyCodable]`
        /// shape `Tool.execute(parameters:)` expects, using the tool's own declared property
        /// names/types so values come back as the right Swift type (not always `String`).
        static func decodeParameters(
            _ content: GeneratedContent,
            schema: Schema
        ) -> [String: AnyCodable] {
            let schemaDict = schema.asDictionary
            let properties = schemaDict["properties"]?.asDictionary ?? [:]
            var result: [String: AnyCodable] = [:]
            for (key, value) in properties {
                let type = value.asDictionary?["type"]?.asString ?? "string"
                switch type {
                case "integer":
                    if let intValue = try? content.value(Int.self, forProperty: key) {
                        result[key] = .number(Double(intValue))
                    }
                case "number":
                    if let doubleValue = try? content.value(Double.self, forProperty: key) {
                        result[key] = .number(doubleValue)
                    }
                case "boolean":
                    if let boolValue = try? content.value(Bool.self, forProperty: key) {
                        result[key] = .boolean(boolValue)
                    }
                default:
                    if let stringValue = try? content.value(String.self, forProperty: key) {
                        result[key] = .string(stringValue)
                    }
                }
            }
            return result
        }
    }
#endif
