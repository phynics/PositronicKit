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
}

// MARK: - PromptSectionProviding

/// Implement to inject `Prompt`(s) into every chat prompt for a thread.
/// Register instances via `ThreadManager.init(sectionProviders:)`.
/// Sections participate in priority sorting and token-budget decisions automatically.
public protocol PromptSectionProviding: Sendable {
    func sections(for context: PromptBuildContext) async -> [any Prompt]
}
