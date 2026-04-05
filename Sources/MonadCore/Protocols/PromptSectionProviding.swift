import Foundation
import MonadPrompt

// MARK: - PromptBuildContext

/// Context available when building a prompt, for dynamic section content.
public struct PromptBuildContext: Sendable {
    public let timelineId: UUID
    public let agentInstanceId: UUID?
    public let message: String

    public init(timelineId: UUID, agentInstanceId: UUID?, message: String) {
        self.timelineId = timelineId
        self.agentInstanceId = agentInstanceId
        self.message = message
    }
}

// MARK: - PromptSectionProviding

/// Implement to inject `ContextSection`(s) into every chat prompt for a timeline.
/// Register instances via `TimelineManager.init(sectionProviders:)`.
/// Sections participate in priority sorting and token-budget decisions automatically.
public protocol PromptSectionProviding: Sendable {
    func sections(for context: PromptBuildContext) async -> [any ContextSection]
}
