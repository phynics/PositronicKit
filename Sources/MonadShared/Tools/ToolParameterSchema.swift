import Foundation

/// Type-safe JSON Schema builder for tool parameters
public struct ToolParameterSchema: Sendable {
    public let schema: [String: AnyCodable]

    public static func object(_ build: (inout ObjectBuilder) -> Void) -> ToolParameterSchema {
        var builder = ObjectBuilder()
        build(&builder)
        return ToolParameterSchema(schema: builder.build())
    }

    public struct ObjectBuilder {
        private var properties: [String: [String: AnyCodable]] = [:]
        private var required: [String] = []

        public init() {}

        public mutating func string(_ name: String, description: String, required isRequired: Bool = false) {
            properties[name] = ["type": .string("string"), "description": .string(description)]
            if isRequired { required.append(name) }
        }

        public mutating func integer(_ name: String, description: String, required isRequired: Bool = false) {
            properties[name] = ["type": .string("integer"), "description": .string(description)]
            if isRequired { required.append(name) }
        }

        public mutating func boolean(_ name: String, description: String, required isRequired: Bool = false) {
            properties[name] = ["type": .string("boolean"), "description": .string(description)]
            if isRequired { required.append(name) }
        }

        public mutating func stringEnum(
            _ name: String, description: String, values: [String], required isRequired: Bool = false
        ) {
            properties[name] = [
                "type": .string("string"),
                "description": .string(description),
                "enum": .array(values.map { .string($0) })
            ]
            if isRequired { required.append(name) }
        }

        func build() -> [String: AnyCodable] {
            var result: [String: AnyCodable] = [
                "type": .string("object"),
                "properties": .dictionary(properties.mapValues { .dictionary($0) })
            ]
            if !required.isEmpty {
                result["required"] = .array(required.map { .string($0) })
            }
            return result
        }
    }
}
