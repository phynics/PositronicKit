import Observation
import PKShared
import PositronicKit

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
    private var activeSendTask: Task<Void, Error>? // swiftlint:disable:this concurrency_stored_task -- owned by actor/@MainActor (see docs/Concurrency/exception-manifest.md)
    private var activeSendGeneration = 0

    /// Creates a controller for a thread driver, optionally seeded with prior messages.
    public init(_ driver: ThreadDriver, messages: [Message] = []) {
        self.driver = driver
        self.messages = messages
    }

    /// Sends a message and mirrors its driver events into the observable state. Supersedes any
    /// in-flight send for this controller's thread.
    public func send(_ message: String) async throws {
        activeSendGeneration += 1
        let generation = activeSendGeneration

        if activeSendTask != nil {
            activeSendTask?.cancel()
            await driver.cancel()
        }
        guard activeSendGeneration == generation else {
            throw CancellationError()
        }
        let task = Task { [driver] in
            try await self.consume(message, from: driver, generation: generation)
        }
        activeSendTask = task
        try await task.value
    }

    private func consume(
        _ content: String,
        from driver: ThreadDriver,
        generation: Int
    ) async throws {
        guard activeSendGeneration == generation else { return }
        messages.append(Message(content: content, role: .user))
        streamingText = ""
        isStreaming = true
        defer {
            if activeSendGeneration == generation {
                isStreaming = false
                activeSendTask = nil
            }
        }

        let stream = try await driver.send(content)
        for try await event in stream {
            try Task.checkCancellation()
            guard activeSendGeneration == generation else { return }
            if let text = event.textContent {
                streamingText += text
            }
            if let completed = event.completedMessage?.message {
                messages.append(completed)
                streamingText = ""
            }
        }
    }

    isolated deinit {
        activeSendTask?.cancel()
    }
}
