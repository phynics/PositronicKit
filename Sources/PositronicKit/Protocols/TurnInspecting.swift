import Foundation
import PKPrompt
import PKShared

public protocol TurnInspecting: Sendable {
    func didComposeTurn(_ inspection: TurnInspection) async
}

public struct TurnInspection: Sendable {
    public let timelineId: UUID
    public let agentInstanceId: UUID?
    public let turnIndex: Int
    public let model: String
    public let rendered: RenderedPrompt
    public let sentMessages: [LLMMessage]
    public let journal: TurnJournalSnapshot
    public let estimatedTokens: Int

    public init(
        timelineId: UUID,
        agentInstanceId: UUID?,
        turnIndex: Int,
        model: String,
        rendered: RenderedPrompt,
        sentMessages: [LLMMessage],
        journal: TurnJournalSnapshot,
        estimatedTokens: Int
    ) {
        self.timelineId = timelineId
        self.agentInstanceId = agentInstanceId
        self.turnIndex = turnIndex
        self.model = model
        self.rendered = rendered
        self.sentMessages = sentMessages
        self.journal = journal
        self.estimatedTokens = estimatedTokens
    }
}

public struct TurnJournalSnapshot: Sendable {
    public let overlay: PromptJournalDiff
    public let stablePrefixCount: Int
    public let didCompact: Bool

    public init(overlay: PromptJournalDiff, stablePrefixCount: Int, didCompact: Bool) {
        self.overlay = overlay
        self.stablePrefixCount = stablePrefixCount
        self.didCompact = didCompact
    }
}
