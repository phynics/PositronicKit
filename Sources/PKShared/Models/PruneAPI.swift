import Foundation

public struct PruneMemoriesRequest: Codable, Sendable {
    public let query: String?
    public let days: Int?
    public let dryRun: Bool

    public init(query: String? = nil, days: Int? = nil, dryRun: Bool = false) {
        self.query = query
        self.days = days
        self.dryRun = dryRun
    }
}

public struct PruneTimelineRequest: Codable, Sendable {
    public let days: Int
    public let excludedTimelineIds: [UUID]
    public let dryRun: Bool

    public init(days: Int, excludedTimelineIds: [UUID] = [], dryRun: Bool = false) {
        self.days = days
        self.excludedTimelineIds = excludedTimelineIds
        self.dryRun = dryRun
    }
}

public struct PruneMessagesRequest: Codable, Sendable {
    public let days: Int
    public let dryRun: Bool

    public init(days: Int, dryRun: Bool = false) {
        self.days = days
        self.dryRun = dryRun
    }
}

public struct PruneResponse: Codable, Sendable {
    public let count: Int
    public let dryRun: Bool

    public init(count: Int, dryRun: Bool) {
        self.count = count
        self.dryRun = dryRun
    }
}
