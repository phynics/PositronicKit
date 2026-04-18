import Foundation
import PKShared

public enum CachePolicy: Sendable, Comparable {
    case stable
    case semiStable
    case volatile
}

public enum CompressionStrategy: Sendable, Equatable {
    case keep
    case truncate(tail: Bool)
    case summarize
    case drop
}

public enum PromptSectionType: Sendable {
    case text
    case list
}

public enum PromptSectionRole: Sendable, Equatable {
    case system
    case context
    case userQuery
    case chatHistory
}

public enum PromptPriority: Int, Sendable {
    case low = 25
    case medium = 50
    case high = 75
    case critical = 100
}

public struct PromptResolutionContext: Sendable {
    public let ancestorPath: [String]
    public let inheritedPriority: Int?
    public let inheritedCompression: CompressionStrategy?
    public let inheritedCachePolicy: CachePolicy?

    public init(
        ancestorPath: [String] = ["prompt"],
        inheritedPriority: Int? = nil,
        inheritedCompression: CompressionStrategy? = nil,
        inheritedCachePolicy: CachePolicy? = nil
    ) {
        self.ancestorPath = ancestorPath
        self.inheritedPriority = inheritedPriority
        self.inheritedCompression = inheritedCompression
        self.inheritedCachePolicy = inheritedCachePolicy
    }

    public func descending(into component: String?) -> PromptResolutionContext {
        guard let component, !component.isEmpty else {
            return self
        }

        var path = ancestorPath
        path.append(component)
        return PromptResolutionContext(
            ancestorPath: path,
            inheritedPriority: inheritedPriority,
            inheritedCompression: inheritedCompression,
            inheritedCachePolicy: inheritedCachePolicy
        )
    }

    public func applying(
        priority: Int? = nil,
        compression: CompressionStrategy? = nil,
        cachePolicy: CachePolicy? = nil
    ) -> PromptResolutionContext {
        PromptResolutionContext(
            ancestorPath: ancestorPath,
            inheritedPriority: priority ?? inheritedPriority,
            inheritedCompression: compression ?? inheritedCompression,
            inheritedCachePolicy: cachePolicy ?? inheritedCachePolicy
        )
    }
}
