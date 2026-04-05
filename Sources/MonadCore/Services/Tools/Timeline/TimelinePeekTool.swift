import Foundation
import MonadShared

/// Allows an agent to read recent messages from a timeline without attaching to it.
public struct TimelinePeekTool: MonadShared.Tool, Sendable {
    public let id = "timeline_peek"
    public let name = "Timeline Peek"
    public let description =
        "Read the most recent messages from a conversation timeline. " +
        "Use this to observe what is happening in a timeline without attaching to it."
    public let requiresPermission = false

    private let messageStore: any MessageStoreProtocol
    private let timelineStore: any TimelinePersistenceProtocol

    public init(messageStore: any MessageStoreProtocol, timelineStore: any TimelinePersistenceProtocol) {
        self.messageStore = messageStore
        self.timelineStore = timelineStore
    }

    public var parametersSchema: [String: AnyCodable] {
        ToolParameterSchema.object { builder in
            builder.string("timeline_id", description: "UUID of the timeline to peek at.", required: true)
            builder.integer("limit", description: "Maximum number of recent messages to return (default: 10, max: 50).")
        }.schema
    }

    public func canExecute() async -> Bool {
        true
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let timelineIdStr: String
        do {
            timelineIdStr = try params.require("timeline_id", as: String.self)
        } catch {
            return .failure(error.localizedDescription)
        }

        guard let timelineId = UUID(uuidString: timelineIdStr) else {
            return .failure("Invalid timeline_id: \(timelineIdStr)")
        }

        // Validate timeline exists and is not private
        guard let timeline = try? await timelineStore.fetchTimeline(id: timelineId) else {
            return .failure("Timeline not found: \(timelineIdStr)")
        }
        if timeline.isPrivate {
            return .failure("Cannot peek at private timelines.")
        }

        let limit = min(params.optional("limit", as: Int.self) ?? 10, 50)
        let messages = try await messageStore.fetchMessages(for: timelineId)
        let recent = Array(messages.suffix(limit))

        struct MessageSummary: Encodable {
            let role: String
            let content: String
            let timestamp: Date
        }

        let summaries = recent.map { MessageSummary(role: $0.role, content: $0.content, timestamp: $0.timestamp) }
        let json = (try? String(data: JSONEncoder().encode(summaries), encoding: .utf8)) ?? "[]"
        return .success("Last \(summaries.count) messages from '\(timeline.title)':\n\(json)")
    }
}
