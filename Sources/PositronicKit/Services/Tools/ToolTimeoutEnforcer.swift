import Foundation
import PKShared

/// Wall-clock timeout enforcement for tool execution.
///
/// Extracted from `ToolRouter.executeWithTimeout` (PKARCH-002). The enforcer races a tool's
/// execution against a wall-clock timeout; whichever finishes first resolves the call. On
/// timeout the tool task is cancelled best-effort and abandoned — the caller returns
/// immediately rather than blocking until an uncooperative tool eventually finishes. The
/// timeout is enforced even for tools whose bodies ignore cooperative cancellation (e.g. a
/// blocking subprocess or synchronous network call).
///
/// The `sleep` closure is injected so tests can substitute an instant-timeout fake clock and
/// exercise the timeout branch without `Task.sleep`'s real-time delay or a `TimelineManager`.
package enum ToolTimeoutEnforcer {
    /// Default wall-clock sleep used when no fake clock is injected. Mirrors `Task.sleep(nanoseconds:)`.
    @usableFromInline
    static let defaultSleep: @Sendable (UInt64) async throws -> Void = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    /// Executes a tool, enforcing a wall-clock timeout.
    ///
    /// - Parameters:
    ///   - tool: The tool to execute.
    ///   - arguments: Decoded arguments to pass to the tool.
    ///   - timeout: Maximum wall-clock seconds to allow before timing out.
    ///   - sleep: Sleep primitive used by the timeout race. Defaults to `Task.sleep(nanoseconds:)`.
    ///     Tests inject an instant-return closure to exercise the timeout branch without real-time
    ///     delay. The closure must throw on cancellation to mirror `Task.sleep` semantics so the
    ///     tool-completion path can cancel the pending timeout cleanly.
    /// - Returns: The tool's `ToolResult` if it completes within the timeout.
    /// - Throws: `ToolError.executionFailed` with a timeout message if the wall-clock race wins;
    ///   any error thrown by the tool body otherwise.
    package static func execute(
        _ tool: AnyTool,
        arguments: [String: AnyCodable],
        timeout: TimeInterval,
        sleep: @Sendable @escaping (UInt64) async throws -> Void = defaultSleep
    ) async throws -> ToolResult {
        let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let timeoutMessage = "Tool execution timed out after \(timeoutDescription(timeout))"

        // Note: this deliberately does not race the two sides inside a `withThrowingTaskGroup`.
        // A task group waits for every child it started before the group's body returns, even
        // children it has cancelled — so if the tool body ignores cooperative cancellation (e.g.
        // a blocking `Thread.sleep` or synchronous network call), a group-based race would block
        // the timeout path for the tool's full uncooperative duration instead of abandoning it
        // promptly. Two ad hoc `Task`s below race by reporting into a shared `AsyncStream`, which
        // — unlike `CheckedContinuation` — tolerates being yielded into or finished more than
        // once, so a straggling loser can't crash a race that's already been resolved. Outer
        // cancellation is handled explicitly by cancelling both tasks and finishing the stream.
        let (stream, continuation) = AsyncStream<RaceOutcome>.makeStream()

        let toolTask = Task {
            do {
                let result = try await tool.execute(parameters: arguments.toAnyDictionary)
                continuation.yield(.completed(result))
            } catch {
                continuation.yield(.failed(error))
            }
        }
        let timeoutTask = Task {
            do {
                try await sleep(nanoseconds)
                continuation.yield(.timedOut)
            } catch {
                continuation.yield(.sleepCancelled)
            }
        }

        return try await withTaskCancellationHandler {
            for await outcome in stream {
                switch outcome {
                case let .completed(result):
                    timeoutTask.cancel()
                    continuation.finish()
                    return result
                case let .failed(error):
                    timeoutTask.cancel()
                    continuation.finish()
                    throw error
                case .timedOut:
                    toolTask.cancel()
                    continuation.finish()
                    throw ToolError.executionFailed(timeoutMessage)
                case .sleepCancelled:
                    continue
                }
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            throw ToolError.executionFailed("Tool race produced no winner")
        } onCancel: {
            toolTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        }
    }

    /// Outcome reported by one side of the tool/timeout race. `sleepCancelled` distinguishes the
    /// timeout task's own cancellation (when the tool wins) from an actual timeout firing.
    private enum RaceOutcome {
        case completed(ToolResult)
        case failed(any Error)
        case timedOut
        case sleepCancelled
    }

    /// Formats a timeout for human-readable error messages: integers render without a decimal,
    /// fractional timeouts keep their decimal representation.
    package static func timeoutDescription(_ timeout: TimeInterval) -> String {
        if timeout.rounded() == timeout {
            return "\(Int(timeout)) seconds"
        }
        return "\(timeout) seconds"
    }
}
