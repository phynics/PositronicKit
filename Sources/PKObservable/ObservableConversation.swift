import Observation
import PKShared
import PositronicKit

private final class ActiveSend: @unchecked Sendable {
    var task: Task<Void, Error>?
}

/// A SwiftUI-friendly controller for a ``Conversation`` cursor.
@MainActor
@Observable
public final class ObservableConversation {
    /// The completed messages of the conversation, oldest first.
    public private(set) var messages: [Message] = []
    /// Whether a send is currently streaming a response.
    public private(set) var isStreaming = false
    /// The partial assistant text of the in-flight turn; empty between turns.
    public private(set) var streamingText = ""

    /// The underlying conversation cursor this controller mirrors.
    public let conversation: Conversation
    private let activeSend = ActiveSend()

    /// Creates a controller for a conversation cursor, optionally seeded with prior messages.
    public init(_ conversation: Conversation, messages: [Message] = []) {
        self.conversation = conversation
        self.messages = messages
    }

    /// Sends a message and mirrors its cursor events into the observable state.
    public func send(_ message: String) async throws {
        if activeSend.task != nil {
            activeSend.task?.cancel()
            await conversation.timelineManager.cancelGeneration(for: conversation.timelineId)
        }
        let task = Task { [conversation] in
            try await self.consume(message, from: conversation)
        }
        activeSend.task = task
        try await task.value
    }

    private func consume(_ content: String, from conversation: Conversation) async throws {
        messages.append(Message(content: content, role: .user))
        streamingText = ""
        isStreaming = true
        defer {
            isStreaming = false
        }

        let stream = try await conversation.send(content)
        for try await event in stream {
            try Task.checkCancellation()
            if let text = event.textContent {
                streamingText += text
            }
            if let completed = event.completedMessage?.message {
                messages.append(completed)
                streamingText = ""
            }
        }
    }

    deinit {
        activeSend.task?.cancel()
    }
}
