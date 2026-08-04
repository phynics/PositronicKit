import Foundation
import PKShared
import PKUtilities

/// Tier-four handle for running an agent against a timeline and instance.
///
/// The handle is intentionally lightweight and fresh per `PositronicKit.makeAgenticRuntime(...)`
/// call. Agent lifecycle operations are delegated to the facade-owned manager, while turns are
/// delegated to the facade's existing chat/tool loop.
public final class AgenticRuntime: Sendable {
    /// The timeline this runtime handle runs turns against.
    public let timelineId: UUID
    /// The agent instance whose identity and workspace bindings each turn runs under.
    public let agentInstanceId: UUID
    /// The facade-owned agent-instance manager, shared by every handle the facade vends.
    public let agentInstanceManager: AgentInstanceManager

    private let kit: PositronicKit

    init(
        kit: PositronicKit,
        timelineId: UUID,
        agentInstanceId: UUID
    ) {
        self.kit = kit
        self.timelineId = timelineId
        self.agentInstanceId = agentInstanceId
        agentInstanceManager = kit.agentInstanceManager
    }

    /// Runs one agent turn through the facade's existing tool loop.
    public func run(
        message: String,
        tools: [any Tool] = [],
        maxTurns: Int = 5,
        systemInstructions: String? = nil
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        try await kit.run(ChatRunRequest(
            timelineId: timelineId,
            message: message,
            tools: tools,
            systemInstructions: systemInstructions,
            agentInstanceId: agentInstanceId,
            maxTurns: maxTurns
        ))
    }
}
