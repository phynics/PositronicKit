import Foundation
import PKShared

/// Structured context data
public struct ContextData: Sendable, Codable {
    public let notes: [ContextFile]
    public let memories: [SemanticSearchResult]
    public let generatedTags: [String]
    public let queryVector: [Double]
    public let augmentedQuery: String?
    public let semanticResults: [SemanticSearchResult]
    public let tagResults: [Memory]
    public let executionTime: TimeInterval

    public init(
        notes: [ContextFile] = [],
        memories: [SemanticSearchResult] = [],
        generatedTags: [String] = [],
        queryVector: [Double] = [],
        augmentedQuery: String? = nil,
        semanticResults: [SemanticSearchResult] = [],
        tagResults: [Memory] = [],
        executionTime: TimeInterval = 0
    ) {
        self.notes = notes
        self.memories = memories
        self.generatedTags = generatedTags
        self.queryVector = queryVector
        self.augmentedQuery = augmentedQuery
        self.semanticResults = semanticResults
        self.tagResults = tagResults
        self.executionTime = executionTime
    }
}
