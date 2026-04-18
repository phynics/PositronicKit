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
