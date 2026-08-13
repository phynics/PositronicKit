import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import PKShared
import PKUtilities

/// Allows an agent to list available (non-private) threads it can observe.
public struct ThreadListTool: PKShared.Tool, Sendable {
    public let callName = "timeline_list"
    public let name = "Timeline List"
    public let description =
        "List all non-private conversation timelines. " +
        "Use this to discover timelines you can peek at or send messages to."
    public let requiresPermission = false

    private let threadStore: any ThreadPersistenceProtocol

    public init(threadStore: any ThreadPersistenceProtocol) {
        self.threadStore = threadStore
    }

    public var parametersSchema: Schema {
        ToolParameterSchema.object {}.schemaDefinition
    }

    public func canExecute() async -> Bool {
        true
    }

    public func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        let threads = try await threadStore.fetchAllThreads(includeArchived: false)
        let visible = threads.filter { !$0.isPrivate }

        let entries = visible.map { timeline -> [String: String] in
            var entry: [String: String] = [
                "id": timeline.id.uuidString,
                "title": timeline.title
            ]
            if let agentId = timeline.attachedAgentInstanceID {
                entry["attachedAgentId"] = agentId.uuidString
            }
            return entry
        }

        let json = (try? String(data: JSONEncoder().encode(entries), encoding: .utf8)) ?? "[]"
        return .success("Available timelines:\n\(json)")
    }
}
