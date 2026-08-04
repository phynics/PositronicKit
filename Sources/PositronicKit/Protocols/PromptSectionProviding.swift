import Foundation
import PKPrompt

// MARK: - PromptBuildContext

/// Context available when building a prompt, for dynamic section content.
public struct PromptBuildContext: Sendable {
    public let timelineID: UUID
    public let agentInstanceID: UUID?
    public let message: String

    public init(timelineID: UUID, agentInstanceID: UUID?, message: String) {
        self.timelineID = timelineID
        self.agentInstanceID = agentInstanceID
        self.message = message
    }

    /// Creates prompt-build context using the legacy identifier spellings.
    @available(*, deprecated, message: "Use init(timelineID:agentInstanceID:message:).")
    public init(timelineId: UUID, agentInstanceId: UUID?, message: String) {
        self.init(timelineID: timelineId, agentInstanceID: agentInstanceId, message: message)
    }

    /// The timeline identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "timelineID")
    public var timelineId: UUID { timelineID }

    /// The agent-instance identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "agentInstanceID")
    public var agentInstanceId: UUID? { agentInstanceID }
}

// MARK: - PromptSectionProviding

/// Implement to inject `Prompt`(s) into every chat prompt for a timeline.
/// Register instances via `TimelineManager.init(sectionProviders:)`.
/// Sections participate in priority sorting and token-budget decisions automatically.
public protocol PromptSectionProviding: Sendable {
    func sections(for context: PromptBuildContext) async -> [any Prompt]
}
