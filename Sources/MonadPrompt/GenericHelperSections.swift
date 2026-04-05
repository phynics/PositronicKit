import Foundation

/// A simple section containing a static text block
public struct TextSection: ContextSection {
    public let id: String
    public let text: String
    public let priority: Int
    public let strategy: CompressionStrategy
    private let _estimatedTokens: Int?

    public init(
        id: String,
        text: String,
        priority: Int = 50,
        strategy: CompressionStrategy = .keep,
        estimatedTokens: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.priority = priority
        self.strategy = strategy
        self._estimatedTokens = estimatedTokens
    }

    public func render() async -> String? {
        guard !text.isEmpty else { return nil }
        return text
    }

    public var estimatedTokens: Int {
        // Fallback if no estimator is available at this level
        // In real usage, one would inject an estimator or use a more specific type
        _estimatedTokens ?? (text.count / 4)
    }
}

/// A no-op section that renders nothing
public struct EmptySection: ContextSection {
    public let id = "empty"
    public let priority = 0
    public let estimatedTokens = 0
    public let strategy: CompressionStrategy = .drop
    public let type: ContextSectionType = .text

    public init() {}

    public func render() async -> String? {
        return nil
    }
}
