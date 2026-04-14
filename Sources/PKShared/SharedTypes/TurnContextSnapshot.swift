import Foundation

/// A serializable representation of the context assembled for a chat turn.
///
/// Mirrors the debug-relevant fields of `ChatTurnContext` and `ContextData`
/// so that `/debug` and other consumers can inspect what the engine used
/// without depending on internal `PositronicKitCore` types.
public struct TurnContextSnapshot: Sendable, Codable, Equatable {
    /// The assembled prompt messages sent to the LLM, in order.
    public let promptMessages: [PromptMessage]

    /// Files retrieved and injected into the prompt.
    public let files: [FileEntry]

    /// Memories retrieved via semantic or tag search.
    public let memories: [MemoryEntry]

    /// Tags generated from the user query for retrieval.
    public let generatedTags: [String]

    /// The augmented query used for semantic search (if any).
    public let augmentedQuery: String?

    /// Time spent gathering context (seconds).
    public let executionTime: TimeInterval

    public init(
        promptMessages: [PromptMessage] = [],
        files: [FileEntry] = [],
        memories: [MemoryEntry] = [],
        generatedTags: [String] = [],
        augmentedQuery: String? = nil,
        executionTime: TimeInterval = 0
    ) {
        self.promptMessages = promptMessages
        self.files = files
        self.memories = memories
        self.generatedTags = generatedTags
        self.augmentedQuery = augmentedQuery
        self.executionTime = executionTime
    }

    /// A serialized prompt message sent to the LLM.
    public struct PromptMessage: Sendable, Codable, Equatable {
        public let role: String
        public let content: String
        /// Estimated token count for this message.
        public let tokenCount: Int

        public init(role: String, content: String, tokenCount: Int = 0) {
            self.role = role
            self.content = content
            self.tokenCount = tokenCount
        }
    }

    /// A context file that was included in the prompt.
    public struct FileEntry: Sendable, Codable, Equatable {
        public let name: String
        public let source: String

        public init(name: String, source: String) {
            self.name = name
            self.source = source
        }
    }

    /// A memory retrieved for context, with its similarity score.
    public struct MemoryEntry: Sendable, Codable, Equatable {
        public let id: UUID
        public let content: String
        public let similarity: Double?

        public init(id: UUID, content: String, similarity: Double? = nil) {
            self.id = id
            self.content = content
            self.similarity = similarity
        }
    }
}
