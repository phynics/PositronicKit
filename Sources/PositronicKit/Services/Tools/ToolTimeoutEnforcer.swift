import Foundation
import PKShared

/// Ensures exactly one winner resolves a raced continuation. `claim()` returns `true` for the first
/// caller only; all subsequent callers get `false` and must not resume the continuation.
actor TimeoutRaceResolver {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

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

        let toolTask = Task { try await tool.execute(parameters: arguments.toAnyDictionary) }
        let timeoutTask = Task { try await sleep(nanoseconds) }
        let resolver = TimeoutRaceResolver()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolResult, Error>) in
                // Tool-completion path.
                Task {
                    let outcome: Result<ToolResult, Error>
                    do {
                        outcome = try .success(await toolTask.value)
                    } catch {
                        outcome = .failure(error)
                    }
                    if await resolver.claim() {
                        timeoutTask.cancel()
                        continuation.resume(with: outcome)
                    }
                }

                // Timeout path.
                Task {
                    // Throws `CancellationError` when the tool finished first and cancelled the
                    // sleep; in that case the tool path owns the result, so do nothing.
                    guard (try? await timeoutTask.value) != nil else { return }
                    if await resolver.claim() {
                        toolTask.cancel()
                        continuation.resume(throwing: ToolError.executionFailed(timeoutMessage))
                    }
                }
            }
        } onCancel: {
            toolTask.cancel()
            timeoutTask.cancel()
        }
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