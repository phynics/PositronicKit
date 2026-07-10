import Foundation
import PKShared

/// Tier-four handle for running an agent against a timeline and instance.
///
/// The handle is intentionally lightweight and fresh per `PositronicKit.agenticRuntime(...)`
/// call. Agent lifecycle operations are delegated to the facade-owned manager, while turns are
/// delegated to the facade's existing chat/tool loop.
public final class AgenticRuntime: Sendable {
    public let timelineId: UUID
    public let workspaceId: UUID?
    public let agentInstanceId: UUID
    public let agentInstanceManager: AgentInstanceManager

    private let kit: PositronicKit

    init(
        kit: PositronicKit,
        timelineId: UUID,
        workspaceId: UUID?,
        agentInstanceId: UUID
    ) {
        self.kit = kit
        self.timelineId = timelineId
        self.workspaceId = workspaceId
        self.agentInstanceId = agentInstanceId
        self.agentInstanceManager = kit.agentInstanceManager
    }

    /// Runs one agent turn through the facade's existing tool loop.
    public func run(
        message: String,
        tools: [AnyTool] = [],
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

