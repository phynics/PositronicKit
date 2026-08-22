import Foundation
import PKContracts
import PKUtilities

/// Structured context data
public struct ContextData: Sendable, Codable {
    public let notes: [ContextNote]
    public let memories: [Memory]
    public let generatedTags: [String]
    public let augmentedQuery: String?
    public let executionTime: TimeInterval

    public init(
        notes: [ContextNote] = [],
        memories: [Memory] = [],
        generatedTags: [String] = [],
        augmentedQuery: String? = nil,
        executionTime: TimeInterval = 0
    ) {
        self.notes = notes
        self.memories = memories
        self.generatedTags = generatedTags
        self.augmentedQuery = augmentedQuery
        self.executionTime = executionTime
    }
}
