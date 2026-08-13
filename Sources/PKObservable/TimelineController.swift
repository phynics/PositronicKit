import Observation
import PKShared
import PositronicKit

private final class ActiveSend: @unchecked Sendable {
    var task: Task<Void, Error>?
    var generation = 0
}

/// A SwiftUI-friendly controller for a ``ThreadDriver``.
///
/// Issuing a new `send(_:)` while one is already in flight cancels/supersedes it: the prior
/// task is cancelled, the driver's underlying generation is cancelled, and the new send starts
/// fresh — mirroring the same superseding-send behavior the former `ObservableConversation`
/// provided.
@MainActor
@Observable
public final class ThreadController {
    /// The completed messages of the thread, oldest first.
    public private(set) var messages: [Message] = []
    /// Whether a send is currently streaming a response.
    public private(set) var isStreaming = false
    /// The partial assistant text of the in-flight turn; empty between turns.
    public private(set) var streamingText = ""

    /// The underlying driver this controller mirrors.
    public let driver: ThreadDriver
    private let activeSend = ActiveSend()

    /// Creates a controller for a thread driver, optionally seeded with prior messages.
    public init(_ driver: ThreadDriver, messages: [Message] = []) {
        self.driver = driver
        self.messages = messages
    }

    /// Sends a message and mirrors its driver events into the observable state. Supersedes any
    /// in-flight send for this controller's thread.
    public func send(_ message: String) async throws {
        activeSend.generation += 1
        let generation = activeSend.generation

        if activeSend.task != nil {
            activeSend.task?.cancel()
            await driver.cancel()
        }
        guard activeSend.generation == generation else {
            throw CancellationError()
        }
        let task = Task { [driver] in
            try await self.consume(message, from: driver, generation: generation)
        }
        activeSend.task = task
        try await task.value
    }

    private func consume(
        _ content: String,
        from driver: ThreadDriver,
        generation: Int
    ) async throws {
        guard activeSend.generation == generation else { return }
        messages.append(Message(content: content, role: .user))
        streamingText = ""
        isStreaming = true
        defer {
            if activeSend.generation == generation {
                isStreaming = false
                activeSend.task = nil
            }
        }

        let stream = try await driver.send(content)
        for try await event in stream {
            try Task.checkCancellation()
            guard activeSend.generation == generation else { return }
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
