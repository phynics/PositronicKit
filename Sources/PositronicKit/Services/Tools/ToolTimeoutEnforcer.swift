import Foundation
import PKShared
import PKUtilities

/// Wall-clock timeout enforcement for tool execution.
///
/// Extracted from `ToolRouter.executeWithTimeout` (PKARCH-002). The enforcer races a tool's
/// execution against a wall-clock timeout; whichever finishes first resolves the call. On
/// timeout the tool task is cancelled best-effort and abandoned — the caller returns
/// immediately rather than blocking until an uncooperative tool eventually finishes. The
/// timeout is enforced even for tools whose bodies ignore cooperative cancellation (e.g. a
/// blocking subprocess or synchronous network call).
///
/// The reported terminal state on timeout depends on the tool's declared `sideEffects`
/// (PKRR-004):
/// - `.none`: the enforcer throws `ToolError.executionFailed` with a clean timeout message.
///   This is the only case where the runtime claims the operation stopped.
/// - `.mutating` / `.externalProcess`: the enforcer throws
///   `ToolError.timedOutButMayStillBeRunning` so the caller is informed that the tool may
///   still be executing out-of-band and retrying may duplicate side effects. The enforcer
///   does NOT block waiting for the uncooperative tool — the result is returned promptly,
///   same as the `.none` case; only the reported status changes.
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
    ///   - timeout: Maximum wall-clock seconds to allow before timing out. Must be finite and
    ///     non-negative; a negative, infinite, or NaN value is treated as invalid and surfaced
    ///     as a clean `executionFailed` error before the race starts (basic validation for
    ///     PKRR-030 — full overflow-safe timeout configuration is tracked there).
    ///   - sleep: Sleep primitive used by the timeout race. Defaults to `Task.sleep(nanoseconds:)`.
    ///     Tests inject an instant-return closure to exercise the timeout branch without real-time
    ///     delay. The closure must throw on cancellation to mirror `Task.sleep` semantics so the
    ///     tool-completion path can cancel the pending timeout cleanly.
    /// - Returns: The tool's `ToolResult` if it completes within the timeout.
    /// - Throws: `ToolError.executionFailed` with a timeout message if the wall-clock race wins
    ///   and the tool is side-effect-free (`.none`); `ToolError.timedOutButMayStillBeRunning`
    ///   if the wall-clock race wins and the tool mutates state (`.mutating`/`.externalProcess`);
    ///   any error thrown by the tool body otherwise.
    package static func execute(
        _ tool: AnyTool,
        arguments: [String: AnyCodable],
        timeout: TimeInterval,
        sleep: @Sendable @escaping (UInt64) async throws -> Void = defaultSleep
    ) async throws -> ToolResult {
        // Basic timeout-value validation (PKRR-030 relationship). Negative, infinite, or NaN
        // timeouts are not valid wall-clock bounds; surface them as a clean execution failure
        // before starting the race so the tool never runs against an unusable timeout.
        guard timeout.isFinite, timeout >= 0 else {
            throw ToolError.executionFailed(
                "Tool execution timeout \(timeout) is not a valid finite non-negative duration"
            )
        }
        // Overflow-safe nanosecond conversion. `TimeInterval` is a `Double`; clamping to the
        // `UInt64` max guards against values whose nanosecond product would overflow.
        let nanoseconds = timeout >= TimeInterval(UInt64.max) / 1_000_000_000
            ? UInt64.max
            : UInt64(timeout * 1_000_000_000)
        let timeoutMessage = "Tool execution timed out after \(ToolError.timeoutDescription(timeout))"

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
                let result = try await tool.execute(parameters: arguments)
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
                    // PKRR-004: only side-effect-free tools get a clean timeout. Tools that
                    // mutate state may still be running out-of-band after best-effort
                    // cancellation, so report the distinct terminal state.
                    switch tool.sideEffects {
                    case .none:
                        throw ToolError.executionFailed(timeoutMessage)
                    case .mutating, .externalProcess:
                        throw ToolError.timedOutButMayStillBeRunning(timeout: timeout)
                    }
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

    /// Formats a timeout for human-readable error messages. Delegates to
    /// `ToolError.timeoutDescription` so the clean-timeout and may-still-be-running messages
    /// share a single source of truth for the wording.
    package static func timeoutDescription(_ timeout: TimeInterval) -> String {
        ToolError.timeoutDescription(timeout)
    }
}
