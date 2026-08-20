import Foundation

/// Represents a tool call from the LLM
public struct ToolCall: Identifiable, Equatable, Codable, Sendable, Hashable {
    /// The provider's tool-call id (e.g. OpenAI's `call_…`). Kept as the original String —
    /// these are arbitrary provider strings, not UUIDs. Coercing them to UUID lost the id and,
    /// because the lossy fallback regenerated a random UUID on every history reload, broke the
    /// assistant↔tool-result pairing on a thread's next turn (YAK-26).
    public let id: String
    public let name: String
    public let arguments: [String: AnyCodable]

    public init(id: String? = nil, name: String, arguments: [String: AnyCodable]) {
        self.id = id ?? UUID().uuidString
        self.name = name
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey {
        case id, name, arguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode as String; previously-persisted rows stored a UUID, which encodes as a string
        // too, so old data still decodes cleanly.
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
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
