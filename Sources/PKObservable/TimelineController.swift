import Foundation
import Observation
import PKContracts
import PositronicKit

/// The terminal error event emitted by a Turn that failed while a controller was consuming it.
public struct TimelineControllerError: Error, Sendable {
    /// The terminal event that describes the Turn failure.
    public let event: TurnEvent.ErrorEvent

    public init(event: TurnEvent.ErrorEvent) {
        self.event = event
    }
}

/// A SwiftUI-friendly controller for a PKRuntime timeline handle.
///
/// Create a controller from a `TimelineHandle` for an Agent-attached Timeline (managed Turns),
/// from a `TimelineHandle` plus `DirectTurnContext` for a detached Timeline (direct Turns), or
/// from a `TimelineFork` for a fork session. The initializer selects the admission path; `send(_:)`
/// behavior is identical on all three.
///
/// Issuing a new `send(_:)` while one is already in flight cancels/supersedes it: the prior
/// task is cancelled, the driver's underlying generation is cancelled, and the new send starts
/// fresh — mirroring the same superseding-send behavior provided by the timeline driver.
@MainActor
@Observable
public final class TimelineController {
    /// The completed messages of the timeline, oldest first.
    public private(set) var messages: [Message] = []
    /// Whether a send is currently streaming a response.
    public private(set) var isStreaming = false
    /// The partial assistant text of the in-flight turn; empty between turns.
    public private(set) var streamingText = ""

    /// The underlying handle this controller mirrors.
    public let driver: TimelineHandle
    /// The admitted Turn most recently consumed by `send(_:)`; nil before the first send.
    public private(set) var lastTurnID: UUID?
    /// The durable terminal outcome of the most recently completed send; nil while streaming
    /// or before the first send. Read from the repository via `TurnHandle.outcome()`, so it
    /// matches what every joiner observes.
    public private(set) var lastOutcome: TurnOutcome?
    /// The controller error thrown by the most recent failed send; nil on success or before sends.
    public private(set) var lastError: TimelineControllerError?
    private let directContext: DirectTurnContext?
    private var activeSendTask: Task<Void, Error>? // swiftlint:disable:this concurrency_stored_task -- owned by actor/@MainActor (see docs/Concurrency/exception-manifest.md)
    private var activeSendGeneration = 0

    /// Creates a managed-path controller for an Agent-attached Timeline, optionally seeded with
    /// prior messages. `send(_:)` admits managed Turns through `TimelineHandle.startTurn(_:)`.
    public init(_ driver: TimelineHandle, messages: [Message] = []) {
        self.driver = driver
        self.directContext = nil
        self.messages = messages
    }

    /// Creates a direct-path controller for a detached Timeline, optionally seeded with prior
    /// messages. `send(_:)` admits direct Turns through
    /// `TimelineHandle.startDirectTurn(_:context:)` using the captured context.
    public init(
        _ driver: TimelineHandle,
        context: DirectTurnContext,
        messages: [Message] = []
    ) {
        self.driver = driver
        self.directContext = context
        self.messages = messages
    }

    /// Creates a controller bound to a fork's ephemeral Timeline. `send(_:)` admits direct
    /// Turns through the fork with its bound context.
    public init(_ fork: TimelineFork, messages: [Message] = []) {
        self.driver = fork.handle
        self.directContext = fork.directContext
        self.messages = messages
    }

    /// Cancels the in-flight send, if any, and the driver's underlying generation.
    public func cancel() async {
        activeSendTask?.cancel()
        await driver.cancel()
    }

    /// Sends a message and mirrors its driver events into the observable state. Supersedes any
    /// in-flight send for this controller's timeline.
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
        from driver: TimelineHandle,
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

        let turn = if let directContext {
            try await driver.startDirectTurn(content, context: directContext)
        } else {
            try await driver.startTurn(content)
        }
        lastTurnID = turn.id
        do {
            for await event in turn.events() {
                try Task.checkCancellation()
                guard activeSendGeneration == generation else { return }
                if case let .error(errorEvent) = event {
                    if case .generationCancelled = errorEvent {
                        throw CancellationError()
                    }
                    throw TimelineControllerError(event: errorEvent)
                }
                if let text = event.textContent {
                    streamingText += text
                }
                if let completed = event.completedMessage?.message {
                    messages.append(completed)
                    streamingText = ""
                }
            }
            lastOutcome = try await turn.outcome()
            lastError = nil
        } catch is CancellationError {
            lastOutcome = try? await turn.outcome()
            throw CancellationError()
        } catch let controllerError as TimelineControllerError {
            lastError = controllerError
            lastOutcome = try? await turn.outcome()
            throw controllerError
        }
    }

    isolated deinit {
        activeSendTask?.cancel()
    }
}
