import Foundation

/// A delta representing a part of a tool call in a streaming response.
///
/// LLMs typically stream tool calls incrementally. `ToolCallDelta` captures each chunk,
/// which must be accumulated by the consumer to form a complete `ToolCall`.
public struct ToolCallDelta: Sendable, Codable {
    /// The index of the tool call in the array of calls for this turn.
    public let index: Int
    /// The unique identifier for this tool call (usually emitted in the first chunk).
    public let id: String?
    /// The name of the tool being called (emitted incrementally).
    public let name: String?
    /// The JSON arguments for the tool (emitted incrementally).
    public let arguments: String?

    public init(index: Int, id: String? = nil, name: String? = nil, arguments: String? = nil) {
        self.index = index
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Metadata about the context sources used to generate a chat response.
///
/// This provides transparency into which memories and files the engine retrieved
/// and provided to the LLM during the context gathering phase.
public struct GenerationMetadata: Sendable, Codable {
    /// List of unique memory identifiers retrieved for this turn.
    public let memories: [UUID]
    /// List of file paths or identifiers retrieved for this turn.
    public let files: [String]
    /// Preparation degradations observed before generation.
    public let diagnostics: [TurnDiagnostic]

    public init(memories: [UUID] = [], files: [String] = [], diagnostics: [TurnDiagnostic] = []) {
        self.memories = memories
        self.files = files
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey { case memories, files, diagnostics }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memories = try container.decode([UUID].self, forKey: .memories)
        files = try container.decode([String].self, forKey: .files)
        diagnostics = try container.decodeIfPresent([TurnDiagnostic].self, forKey: .diagnostics) ?? []
    }
}
