import Foundation
import PKPrompt
import PKContracts
import PKUtilities

/// Shared context state during the gathering pipeline
actor ContextPipelineContext {
    /// The original user query.
    let query: String
    /// Recent conversation history.
    let history: [Message]
    /// Maximum number of results to retrieve.
    let limit: Int
    /// Optional closure to generate tags from a string.
    let tagGenerator: (@Sendable (String) async throws -> [String])?
    /// The time when the pipeline execution started.
    let startTime: TimeInterval

    /// The query after being augmented with history/context.
    private(set) var augmentedQuery: String = ""
    /// Discovered filesystem notes.
    private(set) var notes: [ContextFile] = []
    /// Final merged semantic memories.
    private(set) var memories: [SemanticSearchResult] = []
    /// Tags generated for the current query.
    private(set) var generatedTags: [String] = []
    /// Vector representation of the query.
    private(set) var queryVector: [Double] = []
    /// Raw semantic search results before ranking.
    private(set) var semanticResults: [SemanticSearchResult] = []
    /// Raw tag-based search results before ranking.
    private(set) var tagResults: [Memory] = []
    /// The final assembled context data.
    private(set) var contextData: ContextData?

    /// Initializes a new pipeline context.
    init(
        query: String,
        history: [Message],
        limit: Int,
        tagGenerator: (@Sendable (String) async throws -> [String])?,
        startTime: TimeInterval
    ) {
        self.query = query
        self.history = history
        self.limit = limit
        self.tagGenerator = tagGenerator
        self.startTime = startTime
    }

    /// Assembles and sets the final context data object.
    @discardableResult
    func finalize(executionTime: TimeInterval) -> ContextData {
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
    func setAugmentedQuery(_ query: String) {
        augmentedQuery = query
    }

    /// Updates the gathered results in the context with new data from pipeline stages.
    func setResults(
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
