import Foundation
import PKPrompt

// MARK: - PromptBuildContext

/// Context available when building a prompt, for dynamic section content.
public struct PromptBuildContext: Sendable {
    public let threadID: UUID
    public let agentInstanceID: UUID?
    public let message: String

    public init(threadID: UUID, agentInstanceID: UUID?, message: String) {
        self.threadID = threadID
        self.agentInstanceID = agentInstanceID
        self.message = message
    }

    /// Creates prompt-build context using the deprecated v3 identifier spelling.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public init(timelineID: UUID, agentInstanceID: UUID?, message: String) {
        self.init(threadID: timelineID, agentInstanceID: agentInstanceID, message: message)
    }

    /// Creates prompt-build context using the deprecated lower-camel v3 spellings.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public init(timelineId: UUID, agentInstanceId: UUID?, message: String) {
        self.init(threadID: timelineId, agentInstanceID: agentInstanceId, message: message)
    }

    /// The thread identifier using the deprecated v3 spelling.
    @available(*, deprecated, renamed: "threadID", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var timelineID: UUID { threadID }

    /// The thread identifier using the deprecated lower-camel v3 spelling.
    @available(*, deprecated, renamed: "threadID", message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    public var timelineId: UUID { threadID }

    /// The agent-instance identifier using the legacy 3.x spelling.
    @available(*, deprecated, renamed: "agentInstanceID")
    public var agentInstanceId: UUID? { agentInstanceID }
}

// MARK: - PromptSectionProviding

/// Implement to inject `Prompt`(s) into every chat prompt for a thread.
/// Register instances via `ThreadManager.init(sectionProviders:)`.
/// Sections participate in priority sorting and token-budget decisions automatically.
public protocol PromptSectionProviding: Sendable {
    func sections(for context: PromptBuildContext) async -> [any Prompt]
}
