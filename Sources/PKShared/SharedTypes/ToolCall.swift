import Foundation

/// Represents a tool call from the LLM
public struct ToolCall: Identifiable, Equatable, Codable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let arguments: [String: AnyCodable]

    public init(id: UUID? = nil, name: String, arguments: [String: AnyCodable]) {
        self.id = id ?? UUID()
        self.name = name
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey {
        case id, name, arguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decode([String: AnyCodable].self, forKey: .arguments)
    }

    public static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.name == rhs.name && lhs.arguments == rhs.arguments
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(arguments)
    }
}
