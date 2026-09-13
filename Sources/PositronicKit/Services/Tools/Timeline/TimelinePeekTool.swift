import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import PKContracts
import PKUtilities

/// Allows an agent to read recent messages from a timeline without attaching to it.
public struct TimelinePeekTool: PKContracts.PKTool, Sendable {
    public let callName = "thread_peek"
    public let name = "Timeline Peek"
    public let toolDescription =
        "Read the most recent messages from a timeline. " +
        "Use this to observe what is happening in a timeline without attaching to it."
    public let requiresPermission = false

    private let messageStore: any TimelineMessageStoreProtocol
    private let timelineStore: any TimelinePersistenceProtocol

    public init(messageStore: any TimelineMessageStoreProtocol, timelineStore: any TimelinePersistenceProtocol) {
        self.messageStore = messageStore
        self.timelineStore = timelineStore
    }

    public var parametersSchema: Schema {
        ToolParameterSchema.object {
            JSONProperty(key: "thread_id") {
                JSONString().description("UUID of the timeline to peek at.")
            }
            .required()
            JSONProperty(key: "limit") {
                JSONInteger()
                    .minimum(0)
                    .description("Maximum number of recent messages to return (default: 10, max: 50).")
            }
        }.schemaDefinition
    }

    public func canExecute() async -> Bool {
        true
    }

    public func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let timelineIDString: String
        do {
            timelineIDString = try params.require("thread_id", as: String.self)
        } catch {
            return .failure(error.localizedDescription)
        }

        guard let timelineID = UUID(uuidString: timelineIDString) else {
            return .failure("Invalid timeline_id: \(timelineIDString)")
        }

        // Validate timeline exists and is not private
        guard let timeline = try? await timelineStore.fetchTimeline(id: timelineID) else {
            return .failure("Timeline not found: \(timelineIDString)")
        }
        if timeline.isPrivate {
            return .failure("Cannot peek at private timelines.")
        }

        let requestedLimit = params.optional("limit", as: Int.self) ?? 10
        guard requestedLimit >= 0 else {
            return .failure("limit must be non-negative.")
        }
        let limit = min(requestedLimit, 50)
        let messages = try await messageStore.fetchMessages(for: timelineID)
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
