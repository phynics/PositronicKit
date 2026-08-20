import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import PKContracts
import PKUtilities

/// Allows an agent to post a message to a thread without attaching to it.
///
/// The message is stored as a `system` role message with the agent's ID so it is visible
/// in the thread history. It does NOT trigger LLM generation — messages queue naturally
/// and are processed when an agent next attaches and handles the turn.
public struct ThreadSendTool: PKContracts.Tool, Sendable {
    public let callName = "thread_send"
    public let name = "Thread Send"
    public let description =
        "Post a message to another thread thread without attaching to it. " +
        "The message is queued and will be visible to the next agent that processes that thread."
    public let requiresPermission = true

    private let messageStore: any ThreadMessageStoreProtocol
    private let threadStore: any ThreadPersistenceProtocol
    private let agentID: UUID
    /// The thread this tool sends *from*. The current remote depth is derived from this
    /// thread's message history at execution time, so the recursion guard reflects how deep
    /// the cross-agent chain already is rather than a value captured when the tool was built.
    private let sourceThreadID: UUID
    public init(
        messageStore: any ThreadMessageStoreProtocol,
        threadStore: any ThreadPersistenceProtocol,
        agentID: UUID,
        sourceThreadID: UUID
    ) {
        self.messageStore = messageStore
        self.threadStore = threadStore
        self.agentID = agentID
        self.sourceThreadID = sourceThreadID
    }

    public var parametersSchema: Schema {
        ToolParameterSchema.object {
            JSONProperty(key: "thread_id") {
                JSONString().description("UUID of the destination thread.")
            }
            .required()
            JSONProperty(key: "message") {
                JSONString().description("The message content to post to the thread.")
            }
            .required()
        }.schemaDefinition
    }

    public func canExecute() async -> Bool {
        true
    }

    public func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        let params = ToolParameters(parameters)
        let threadIDString: String
        let messageContent: String

        do {
            threadIDString = try params.require("thread_id", as: String.self)
            messageContent = try params.require("message", as: String.self)
        } catch {
            return .failure(error.localizedDescription)
        }

        guard let threadID = UUID(uuidString: threadIDString) else {
            return .failure("Invalid thread_id: \(threadIDString)")
        }

        // Derive the current depth from the source thread's history: the deepest hop that
        // reached this thread. A fresh thread has no remote messages and starts at 0.
        let sourceMessages = (try? await messageStore.fetchMessages(for: sourceThreadID)) ?? []
        let currentRemoteDepth = sourceMessages.map(\.remoteDepth).max() ?? 0
        let nextDepth = currentRemoteDepth + 1
        if nextDepth > TurnEngine.Constants.maxRemoteDepth {
            return .failure(
                "Remote depth limit exceeded (\(nextDepth) > \(TurnEngine.Constants.maxRemoteDepth)). " +
                    "Cross-agent send chains are limited to \(TurnEngine.Constants.maxRemoteDepth) hops to prevent infinite recursion."
            )
        }

        // Validate target thread exists and is accessible
        guard let thread = try? await threadStore.fetchThread(id: threadID) else {
            return .failure("Thread not found: \(threadIDString)")
        }
        if thread.isPrivate && thread.attachedAgentID != agentID {
            return .failure("Cannot send to another agent's private thread.")
        }

        let msg = ThreadMessage(
            threadID: threadID,
            role: .system,
            content: "[Agent \(agentID.uuidString.prefix(8))]: \(messageContent)",
            agentID: agentID,
            remoteDepth: nextDepth
        )
        try await messageStore.saveMessage(msg)

        return .success("Message posted to thread '\(thread.title)'.")
    }
}
