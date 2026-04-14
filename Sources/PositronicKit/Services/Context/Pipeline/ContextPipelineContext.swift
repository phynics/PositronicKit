import Foundation
import PKPrompt
import PKShared

/// Shared context state during the gathering pipeline
public actor ContextPipelineContext {
    /// The original user query.
    public let query: String
    /// Recent conversation history.
    public let history: [Message]
    /// Maximum number of results to retrieve.
    public let limit: Int
    /// Optional closure to generate tags from a string.
    public let tagGenerator: (@Sendable (String) async throws -> [String])?
    /// The time when the pipeline execution started.
    public let startTime: CFAbsoluteTime

    /// The query after being augmented with history/context.
    public private(set) var augmentedQuery: String = ""
    /// Discovered filesystem notes.
    public private(set) var notes: [ContextFile] = []
    /// Final merged semantic memories.
    public private(set) var memories: [SemanticSearchResult] = []
    /// Tags generated for the current query.
    public private(set) var generatedTags: [String] = []
    /// Vector representation of the query.
    public private(set) var queryVector: [Double] = []
    /// Raw semantic search results before ranking.
    public private(set) var semanticResults: [SemanticSearchResult] = []
    /// Raw tag-based search results before ranking.
    public private(set) var tagResults: [Memory] = []
    /// The final assembled context data.
    public private(set) var contextData: ContextData?

    /// Initializes a new pipeline context.
    /// - Parameters:
    ///   - query: The user's input query.
    ///   - history: Recent conversation messages.
    ///   - limit: Result limit for retrieval.
    ///   - tagGenerator: Optional tag generation logic.
    ///   - startTime: Pipeline start timestamp.
    public init(
        query: String,
        history: [Message],
        limit: Int,
        tagGenerator: (@Sendable (String) async throws -> [String])?,
        startTime: CFAbsoluteTime
    ) {
        self.query = query
        self.history = history
        self.limit = limit
        self.tagGenerator = tagGenerator
        self.startTime = startTime
    }

    /// Assembles and sets the final context data object.
    /// - Parameter executionTime: The total time taken (in seconds) to gather all context data.
    /// - Returns: A fully populated `ContextData` object containing notes, memories, and metadata.
    @discardableResult
    public func finalize(executionTime: TimeInterval) -> ContextData {
        let data = ContextData(
            notes: notes,
            memories: memories,
            generatedTags: generatedTags,
            queryVector: queryVector,
            augmentedQuery: augmentedQuery,
            semanticResults: semanticResults,
            tagResults: tagResults,
            executionTime: executionTime
        )
        contextData = data
        return data
    }

    /// Sets the augmented version of the search query.
    /// - Parameter query: The final augmented query string used for retrieval.
    public func setAugmentedQuery(_ query: String) {
        augmentedQuery = query
    }

    /// Updates the gathered results in the context with new data from pipeline stages.
    /// - Parameters:
    ///   - notes: Discovered filesystem notes, if any.
    ///   - memories: Final ranked and merged semantic memories, if any.
    ///   - tags: Collection of generated search tags, if any.
    ///   - vector: The embedding vector generated for the query, if any.
    ///   - semanticResults: Raw results from semantic search before ranking, if any.
    ///   - tagResults: Raw memories discovered via tag matching before ranking, if any.
    public func setResults(
        notes: [ContextFile]? = nil,
        memories: [SemanticSearchResult]? = nil,
        tags: [String]? = nil,
        vector: [Double]? = nil,
        semanticResults: [SemanticSearchResult]? = nil,
        tagResults: [Memory]? = nil
    ) {
        if let notes { self.notes = notes }
        if let memories { self.memories = memories }
        if let tags { generatedTags = tags }
        if let vector { queryVector = vector }
        if let semanticResults { self.semanticResults = semanticResults }
        if let tagResults { self.tagResults = tagResults }
    }
}
