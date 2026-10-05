import Foundation
import PKContracts

/// A detached, ephemeral clone of one Timeline's session.
///
/// A fork copies the source Timeline's durable history into its own in-memory runtime. It shares
/// the source runtime's language model, Agent store, and Workspace stores, but owns a separate
/// `TimelineRuntimeRepository` and prompt-journal state, so its history, Turn ledger, tool
/// intents and results, and Request-ID space are isolated. The source Timeline is unreachable
/// from fork writes.
///
/// A fork runs ordinary Turns on the explicit direct path: it is detached (no attached Agent) and
/// uses the ``DirectTurnContext`` supplied at fork time. Tool access is read-only — the default
/// filesystem tool set and the Timeline observation tools — with no Timeline-send tool and no
/// write path.
///
/// The fork's runtime is released when this handle is released. A fork is never durable: its
/// Timeline, messages, and Turns live only for the lifetime of the handle.
///
/// - Note: A fork is a semantic session clone, not a provider-cache-exact one. Its first request
///   re-assembles a prompt from the cloned history, so it does not byte-match the source's wire
///   request.
public final class TimelineFork: Sendable {
    /// The ephemeral Timeline identifier owned by this fork. Distinct from the source Timeline.
    public let timelineID: UUID

    private let runtime: PKRuntime
    private let context: DirectTurnContext

    init(timelineID: UUID, runtime: PKRuntime, context: DirectTurnContext) {
        self.timelineID = timelineID
        self.runtime = runtime
        self.context = context
    }

    /// Starts a direct Turn on the fork from a plain-text user message.
    ///
    /// - Parameters:
    ///   - message: The user message to admit.
    ///   - options: Per-Turn configuration that does not repeat this fork's Timeline identity.
    /// - Returns: A handle for the admitted Turn, running on the fork's runtime.
    public func startTurn(
        _ message: String,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        try await startTurn(MessageContent(message), options: options)
    }

    /// Starts a direct Turn on the fork from ordered text and media content.
    ///
    /// - Parameters:
    ///   - content: The ordered text and media content to admit.
    ///   - options: Per-Turn configuration that does not repeat this fork's Timeline identity.
    /// - Returns: A handle for the admitted Turn, running on the fork's runtime.
    public func startTurn(
        _ content: MessageContent,
        options: TurnOptions = .init()
    ) async throws -> TurnHandle {
        try await runtime.timelines
            .open(timelineID)
            .startDirectTurn(content, context: context, options: options)
    }

    /// Reads the fork's own durable history in oldest-first order.
    public func messages() async throws -> [TimelineMessage] {
        try await runtime.timelines.messages(for: timelineID)
    }

    /// Cancels any in-flight generation on the fork.
    public func cancel() async {
        await runtime.timelines.open(timelineID).cancel()
    }
}
