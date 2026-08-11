import Foundation
import PKShared
import PKUtilities

/// Tier-four handle for running an agent against a timeline and instance.
///
/// The handle is intentionally lightweight and fresh per `PositronicKit.agenticRuntime(...)`
/// call. Agent lifecycle operations are delegated to the facade-owned manager, while turns are
/// delegated to the facade's existing chat/tool loop.
public final class AgenticRuntime: Sendable {
    /// The timeline this runtime handle runs turns against.
    public let timelineID: UUID
    /// The agent instance whose identity and workspace bindings each turn runs under.
    public let agentInstanceID: UUID
    /// The facade-owned agent-instance manager, shared by every handle the facade vends.
    public let agentInstanceManager: AgentInstanceManager

    private let kit: PositronicKit

    init(
        kit: PositronicKit,
        timelineID: UUID,
        agentInstanceID: UUID
    ) {
        self.kit = kit
        self.timelineID = timelineID
        self.agentInstanceID = agentInstanceID
        agentInstanceManager = kit.agentInstanceManager
    }

    /// The timeline identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "timelineID")
    public var timelineId: UUID { timelineID }

    /// The agent-instance identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "agentInstanceID")
    public var agentInstanceId: UUID { agentInstanceID }

    /// Runs one agent turn through the facade's existing tool loop.
    ///
    /// The agent must already be attached to `timelineID`; this handle does not establish the
    /// attachment. An invalid relationship throws ``AgentInstanceError/timelineAgentMismatch``
    /// before the turn is persisted or dispatched to the provider.
    public func run(
        message: String,
        tools: [any Tool] = [],
        maxTurns: Int = 5,
        systemInstructions: String? = nil
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try await kit.run(ChatRunRequest(
            timelineID: timelineID,
            message: message,
            tools: tools,
            systemInstructions: systemInstructions,
            agentInstanceID: agentInstanceID,
            maxTurns: maxTurns
        ))
    }
}
