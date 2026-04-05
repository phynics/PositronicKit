import Foundation

/// A delta representing a part of a tool call in a streaming response.
///
/// LLMs typically stream tool calls incrementally. `ToolCallDelta` captures each chunk,
/// which must be accumulated by the client to form a complete `ToolCall`.
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
public struct ChatMetadata: Sendable, Codable {
    /// List of unique memory identifiers retrieved for this turn.
    public let memories: [UUID]
    /// List of file paths or identifiers retrieved for this turn.
    public let files: [String]

    public init(memories: [UUID] = [], files: [String] = []) {
        self.memories = memories
        self.files = files
    }
}
