import Foundation

public struct CreateMemoryRequest: Codable, Sendable {
    public let content: String
    public let title: String?
    public let tags: [String]?

    public init(content: String, title: String? = nil, tags: [String]? = nil) {
        self.content = content
        self.title = title
        self.tags = tags
    }
}

public struct MemorySearchRequest: Codable, Sendable {
    public let query: String
    public let limit: Int?

    public init(query: String, limit: Int? = nil) {
        self.query = query
        self.limit = limit
    }
}

public struct UpdateMemoryRequest: Codable, Sendable {
    public let content: String?
    public let tags: [String]?

    public init(content: String? = nil, tags: [String]? = nil) {
        self.content = content
        self.tags = tags
    }
}
