import Foundation
import MonadShared

/// Allows an agent to list available (non-private) timelines it can observe.
public struct TimelineListTool: MonadShared.Tool, Sendable {
    public let id = "timeline_list"
    public let name = "Timeline List"
    public let description =
        "List all non-private conversation timelines. " +
        "Use this to discover timelines you can peek at or send messages to."
    public let requiresPermission = false

    private let timelineStore: any TimelinePersistenceProtocol

    public init(timelineStore: any TimelinePersistenceProtocol) {
        self.timelineStore = timelineStore
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object { _ in }.schema
    }

    public func canExecute() async -> Bool {
        true
    }

    public func execute(parameters _: [String: Any]) async throws -> ToolResult {
        let timelines = try await timelineStore.fetchAllTimelines(includeArchived: false)
        let visible = timelines.filter { !$0.isPrivate }

        let entries = visible.map { timeline -> [String: String] in
            var entry: [String: String] = [
                "id": timeline.id.uuidString,
                "title": timeline.title
            ]
            if let agentId = timeline.attachedAgentInstanceId {
                entry["attachedAgentId"] = agentId.uuidString
            }
            return entry
        }

        let json = (try? String(data: JSONEncoder().encode(entries), encoding: .utf8)) ?? "[]"
        return .success("Available timelines:\n\(json)")
    }
}
