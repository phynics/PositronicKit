import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import PKContracts
import PKUtilities

/// Allows an agent to read recent messages from a thread without attaching to it.
public struct ThreadPeekTool: PKContracts.Tool, Sendable {
    public let callName = "thread_peek"
    public let name = "Thread Peek"
    public let description =
        "Read the most recent messages from a thread thread. " +
        "Use this to observe what is happening in a thread without attaching to it."
    public let requiresPermission = false

    private let messageStore: any ThreadMessageStoreProtocol
    private let threadStore: any ThreadPersistenceProtocol

    public init(messageStore: any ThreadMessageStoreProtocol, threadStore: any ThreadPersistenceProtocol) {
        self.messageStore = messageStore
        self.threadStore = threadStore
    }

    public var parametersSchema: Schema {
        ToolParameterSchema.object {
            JSONProperty(key: "thread_id") {
                JSONString().description("UUID of the thread to peek at.")
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
        let threadIDString: String
        do {
            threadIDString = try params.require("thread_id", as: String.self)
        } catch {
            return .failure(error.localizedDescription)
        }

        guard let threadID = UUID(uuidString: threadIDString) else {
            return .failure("Invalid thread_id: \(threadIDString)")
        }

        // Validate thread exists and is not private
        guard let thread = try? await threadStore.fetchThread(id: threadID) else {
            return .failure("Thread not found: \(threadIDString)")
        }
        if thread.isPrivate {
            return .failure("Cannot peek at private threads.")
        }

        let requestedLimit = params.optional("limit", as: Int.self) ?? 10
        guard requestedLimit >= 0 else {
            return .failure("limit must be non-negative.")
        }
        let limit = min(requestedLimit, 50)
        let messages = try await messageStore.fetchMessages(for: threadID)
        let recent = Array(messages.suffix(limit))

        struct MessageSummary: Encodable {
            let role: String
            let content: String
            let timestamp: Date
        }

        let summaries = recent.map { MessageSummary(role: $0.role, content: $0.content, timestamp: $0.timestamp) }
        let json = (try? String(data: JSONEncoder().encode(summaries), encoding: .utf8)) ?? "[]"
        return .success("Last \(summaries.count) messages from '\(thread.title)':\n\(json)")
    }
}
