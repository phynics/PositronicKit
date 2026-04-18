import Foundation

public enum StructuredOutputRequest: Sendable, Equatable, Codable {
    case jsonObject
    case jsonSchema(StructuredOutputSchema)
}

public struct StructuredOutputSchema: Sendable, Equatable, Codable {
    public let name: String
    public let description: String?
    public let schema: [String: AnyCodable]
    public let strict: Bool

    public init(
        name: String,
        description: String? = nil,
        schema: [String: AnyCodable],
        strict: Bool = true
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.strict = strict
    }
}
