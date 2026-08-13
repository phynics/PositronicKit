import Foundation
import PKShared
import PKUtilities

/// Tier-four handle for running an agent against a thread and instance.
///
/// The handle is intentionally lightweight and fresh per `PositronicKit.agenticRuntime(...)`
/// call. Agent lifecycle operations are delegated to the facade-owned manager, while turns are
/// delegated to the facade's existing chat/tool loop.
public final class AgenticRuntime: Sendable {
    /// The thread this runtime handle runs turns against.
    public let threadID: UUID
    /// The agent instance whose identity and workspace bindings each turn runs under.
    public let agentInstanceID: UUID?
    /// The facade-owned agent-instance manager, shared by every handle the facade vends.
    public let agentInstanceManager: AgentInstanceManager

    private let kit: PositronicKit

    init(
        kit: PositronicKit,
        threadID: UUID,
        agentInstanceID: UUID?
    ) {
        self.kit = kit
        self.threadID = threadID
        self.agentInstanceID = agentInstanceID
        agentInstanceManager = kit.agentInstanceManager
    }

    /// Deprecated v3 initializer retained for source compatibility.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    convenience init(
        kit: PositronicKit,
        timelineID: UUID,
        agentInstanceID: UUID?
    ) {
        self.init(kit: kit, threadID: timelineID, agentInstanceID: agentInstanceID)
    }

    /// Deprecated v3 spelling for the thread identifier.
    @available(*, deprecated, renamed: "threadID", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var timelineID: UUID { threadID }

    /// Deprecated v3 spelling for the thread identifier.
    @available(*, deprecated, renamed: "threadID", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var timelineId: UUID { threadID }

    /// The agent-instance identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "agentInstanceID")
    public var agentInstanceId: UUID? { agentInstanceID }

    /// Runs one agent turn through the facade's existing tool loop.
    ///
    /// The agent must already be attached to `threadID`; this handle does not establish the
    /// attachment. An invalid relationship throws ``AgentInstanceError/timelineAgentMismatch``
    /// before the turn is persisted or dispatched to the provider.
    public func run(
        message: String,
        tools: [any Tool] = [],
        maxTurns: Int = 5,
        systemInstructions: String? = nil
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try await kit.run(ChatRunRequest(
            threadID: threadID,
            message: message,
            tools: tools,
            systemInstructions: systemInstructions,
            agentInstanceID: agentInstanceID,
            maxTurns: maxTurns
        ))
    }
}
