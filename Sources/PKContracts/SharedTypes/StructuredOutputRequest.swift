import Foundation
import struct JSONSchema.Schema

public enum StructuredOutputRequest: Sendable, Equatable, Codable {
    case jsonObject
    case jsonSchema(StructuredOutputSchema)
}

public struct StructuredOutputSchema: Sendable, Equatable, Codable {
    public let name: String
    public let description: String?
    public let schema: Schema
    public let isStrict: Bool

    public init(
        name: String,
        description: String? = nil,
        schema: Schema,
        isStrict: Bool = true
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.isStrict = isStrict
    }
}
