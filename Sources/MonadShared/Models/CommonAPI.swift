import Foundation

public struct PaginationRequest: Codable, Sendable {
    public let page: Int
    public let perPage: Int

    public init(page: Int = 1, perPage: Int = 20) {
        self.page = max(1, page)
        self.perPage = max(1, min(100, perPage))
    }
}

public struct PaginationMetadata: Codable, Sendable {
    public let page: Int
    public let perPage: Int
    public let totalItems: Int
    public let totalPages: Int

    public init(page: Int, perPage: Int, totalItems: Int) {
        self.page = page
        self.perPage = perPage
        self.totalItems = totalItems
        self.totalPages = Int(ceil(Double(totalItems) / Double(perPage)))
    }
}

public struct PaginatedResponse<T: Codable & Sendable>: Codable, Sendable {
    public let items: [T]
    public let metadata: PaginationMetadata

    public init(items: [T], metadata: PaginationMetadata) {
        self.items = items
        self.metadata = metadata
    }
}

public struct APIErrorDetail: Codable, Sendable {
    public let code: String
    public let message: String
    public let details: [String: String]?

    public init(code: String, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct APIErrorResponse: Codable, Sendable {
    public let error: APIErrorDetail

    public init(error: APIErrorDetail) {
        self.error = error
    }
}
