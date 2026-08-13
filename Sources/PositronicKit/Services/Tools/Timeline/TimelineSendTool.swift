import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import PKShared
import PKUtilities

/// Allows an agent to post a message to a thread without attaching to it.
///
/// The message is stored as a `system` role message with the agent's ID so it is visible
/// in the timeline history. It does NOT trigger LLM generation — messages queue naturally
/// and are processed when an agent next attaches and handles the turn.
public struct ThreadSendTool: PKShared.Tool, Sendable {
    public let callName = "timeline_send"
    public let name = "Timeline Send"
    public let description =
        "Post a message to another conversation timeline without attaching to it. " +
        "The message is queued and will be visible to the next agent that processes that timeline."
    public let requiresPermission = true

    private let messageStore: any MessageStoreProtocol
    private let threadStore: any ThreadPersistenceProtocol
    private let agentInstanceID: UUID
    /// The thread this tool sends *from*. The current remote depth is derived from this
    /// timeline's message history at execution time, so the recursion guard reflects how deep
    /// the cross-agent chain already is rather than a value captured when the tool was built.
    private let sourceThreadID: UUID
    public init(
        messageStore: any MessageStoreProtocol,
        threadStore: any ThreadPersistenceProtocol,
        agentInstanceID: UUID,
        sourceThreadID: UUID
    ) {
        self.messageStore = messageStore
        self.threadStore = threadStore
        self.agentInstanceID = agentInstanceID
        self.sourceThreadID = sourceThreadID
    }

    public var parametersSchema: Schema {
        ToolParameterSchema.object {
            JSONProperty(key: "timeline_id") {
                JSONString().description("UUID of the destination timeline.")
            }
            .required()
            JSONProperty(key: "message") {
                JSONString().description("The message content to post to the timeline.")
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
            threadIDString = try params.require("timeline_id", as: String.self)
            messageContent = try params.require("message", as: String.self)
        } catch {
            return .failure(error.localizedDescription)
        }

        guard let threadID = UUID(uuidString: threadIDString) else {
            return .failure("Invalid timeline_id: \(threadIDString)")
        }

        // Derive the current depth from the source timeline's history: the deepest hop that
        // reached this timeline. A fresh timeline has no remote messages and starts at 0.
        let sourceMessages = (try? await messageStore.fetchMessages(for: sourceThreadID)) ?? []
        let currentRemoteDepth = sourceMessages.map(\.remoteDepth).max() ?? 0
        let nextDepth = currentRemoteDepth + 1
        if nextDepth > ChatEngine.Constants.maxRemoteDepth {
            return .failure(
                "Remote depth limit exceeded (\(nextDepth) > \(ChatEngine.Constants.maxRemoteDepth)). " +
                    "Cross-agent send chains are limited to \(ChatEngine.Constants.maxRemoteDepth) hops to prevent infinite recursion."
            )
        }

        // Validate target timeline exists and is accessible
        guard let thread = try? await threadStore.fetchThread(id: threadID) else {
            return .failure("Timeline not found: \(threadIDString)")
        }
        if thread.isPrivate && thread.attachedAgentInstanceID != agentInstanceID {
            return .failure("Cannot send to another agent's private timeline.")
        }

        let msg = ConversationMessage(
            threadID: threadID,
            role: .system,
            content: "[Agent \(agentInstanceID.uuidString.prefix(8))]: \(messageContent)",
            agentInstanceID: agentInstanceID,
            remoteDepth: nextDepth
        )
        try await messageStore.saveMessage(msg)

        return .success("Message posted to timeline '\(thread.title)'.")
    }
}
