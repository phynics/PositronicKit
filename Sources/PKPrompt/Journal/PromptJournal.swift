import Foundation
import PKShared

/// Errors raised when a rendered prompt cannot be safely journaled.
public enum PromptJournalValidationError: PKError, Sendable, Equatable {
    /// More than one stable section used the same identifier.
    case duplicateStableSectionIDs([String])
    /// More than one semi-stable section used the same identifier.
    case duplicateSemiStableSectionIDs([String])

    public var errorDomain: String {
        PKErrorDomain.prompt
    }

    public var errorCode: Int {
        switch self {
        case .duplicateStableSectionIDs: return 1301
        case .duplicateSemiStableSectionIDs: return 1302
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case let .duplicateStableSectionIDs(ids):
            return "Prompt journaling found duplicate stable section identifiers: \(ids.joined(separator: ", "))."
        case let .duplicateSemiStableSectionIDs(ids):
            return "Prompt journaling found duplicate semi-stable section identifiers: \(ids.joined(separator: ", "))."
        }
    }

    public var remediation: String? {
        "Ensure each stable and semi-stable prompt section uses a unique identifier."
    }
}

/// Tracks prompt snapshots across turns and projects them into journal layers.
///
/// `PromptJournal` keeps a committed non-volatile base, compares new rendered prompts against
/// that base, and produces a `PromptJournalPlan` describing which sections belong in the base,
/// overlay, and volatile layers for the current observation.
///
/// This is the prompt-layer journaling abstraction intended for public use. Reach for it when you
/// want to reason about prompt evolution directly, outside the runtime loop.
public struct PromptJournal: Sendable {
    /// Validation failures raised while observing a rendered prompt.
    public typealias ValidationError = PromptJournalValidationError

    /// Codable, Sendable snapshot of the journal's complete replay state.
    public struct State: Codable, Sendable, Equatable {
        /// Sections committed as the journal's non-volatile base.
        public let committedBaseSections: [RenderedPrompt.Section]
        /// Sections from the latest accepted observation, including volatile sections.
        public let latestObservedSections: [RenderedPrompt.Section]
        /// Number of messages accumulated since the last compaction.
        public let appendedMessageCount: Int
        /// Estimated tokens accumulated since the last compaction.
        public let appendedTokens: Int
        /// Thresholds used to decide when append pressure triggers compaction.
        public let thresholds: PromptJournalCompactionThresholds

        public init(
            committedBaseSections: [RenderedPrompt.Section],
            latestObservedSections: [RenderedPrompt.Section],
            appendedMessageCount: Int,
            appendedTokens: Int,
            thresholds: PromptJournalCompactionThresholds
        ) {
            self.committedBaseSections = committedBaseSections
            self.latestObservedSections = latestObservedSections
            self.appendedMessageCount = appendedMessageCount
            self.appendedTokens = appendedTokens
            self.thresholds = thresholds
        }
    }

    private var pressure: AppendPressure
    private var committedBaseSections: [RenderedPrompt.Section] = []
    private var latestObservedSections: [RenderedPrompt.Section] = []

    /// Creates an empty prompt journal with no committed base.
    ///
    /// - Parameter thresholds: Append-pressure thresholds that trigger auto-compaction of the
    ///   latest accepted observation into a new committed base on the next `observe(_:)`.
    public init(thresholds: PromptJournalCompactionThresholds = .default) {
        pressure = AppendPressure(thresholds: thresholds)
    }

    /// Restores a journal from a previously captured state snapshot.
    public init(state: State) {
        pressure = AppendPressure(
            thresholds: state.thresholds,
            appendedMessageCount: state.appendedMessageCount,
            appendedTokens: state.appendedTokens
        )
        committedBaseSections = state.committedBaseSections
        latestObservedSections = state.latestObservedSections
    }

    /// The complete state needed to resume observation with identical plans.
    public var state: State {
        State(
            committedBaseSections: committedBaseSections,
            latestObservedSections: latestObservedSections,
            appendedMessageCount: pressure.appendedMessageCount,
            appendedTokens: pressure.appendedTokens,
            thresholds: pressure.thresholds
        )
    }

    /// Observes a rendered prompt and returns the journal plan for the current turn.
    ///
    /// The first observation materializes all non-volatile sections into the committed base.
    /// Subsequent observations emit semistable changes as overlay sections unless stable content
    /// changes, in which case the base is rebuilt and the returned plan requests a hard reset.
    ///
    /// - Parameter prompt: The rendered prompt snapshot to journal.
    /// - Returns: A plan describing the current base, overlay, and volatile layers.
    /// - Throws: ``ValidationError`` when stable or semi-stable section identifiers are duplicated.
    public mutating func observe(_ prompt: RenderedPrompt) throws -> PromptJournalPlan {
        let currentSections = prompt.sections
        try PromptJournalDiffer.validate(committedBaseSections)
        try PromptJournalDiffer.validate(latestObservedSections)
        try PromptJournalDiffer.validate(currentSections)
        compactIfNeeded()
        defer { latestObservedSections = currentSections }

        let evaluation = try PromptJournalDiffer.evaluate(
            committedBaseSections: committedBaseSections,
            currentSections: currentSections
        )
        committedBaseSections = evaluation.nextCommittedBaseSections

        return PromptJournalPlanBuilder.makePlan(
            committedBaseSections: committedBaseSections,
            currentSections: currentSections,
            overlaySections: evaluation.overlaySections,
            requiresHardReset: evaluation.requiresHardReset,
            diff: evaluation.diff,
            emissionMode: evaluation.emissionMode
        )
    }

    /// Records append pressure from accepted downstream conversation messages.
    ///
    /// Use this after the current journal observation has been accepted by a caller and appended
    /// to conversation history. When append pressure exceeds `thresholds`, the journal promotes
    /// the latest accepted observation into a new committed base on the next `observe(_:)`.
    public mutating func recordAppend(messageCount: Int, estimatedTokens: Int) {
        pressure.recordAppend(messageCount: messageCount, estimatedTokens: estimatedTokens)
    }

    /// Records append pressure from concrete appended messages.
    public mutating func recordAppend(messages: [Message]) {
        pressure.recordAppend(messages: messages)
    }

    /// Whether the latest accepted observation should be compacted before the next diff.
    public var shouldCompact: Bool {
        pressure.shouldCompact
    }

    /// Promotes the latest observed non-volatile sections into the committed base.
    ///
    /// Use compaction after an overlay has been accepted and should become the new baseline for
    /// future diffing.
    ///
    /// - Returns: A plan representing the compacted state, or `nil` when nothing has been observed.
    public mutating func compact() -> PromptJournalPlan? {
        guard !latestObservedSections.isEmpty else {
            pressure.reset()
            return nil
        }

        committedBaseSections = latestObservedSections.filter { $0.cachePolicy != .volatile }
        pressure.reset()
        return PromptJournalPlanBuilder.makePlan(
            committedBaseSections: committedBaseSections,
            currentSections: latestObservedSections,
            overlaySections: [],
            requiresHardReset: false,
            diff: PromptJournalDiff(),
            emissionMode: .snapshot
        )
    }

    /// Clears the current observation and append pressure while retaining the committed base.
    public mutating func resetKeepingCommittedState() {
        latestObservedSections = []
        pressure.reset()
    }

    /// Clears the current observation, append pressure, and committed base.
    public mutating func resetDiscardingCommittedState() {
        resetKeepingCommittedState()
        committedBaseSections = []
    }

    private mutating func compactIfNeeded() {
        guard pressure.shouldCompact else {
            return
        }
        if !latestObservedSections.isEmpty {
            committedBaseSections = latestObservedSections.filter { $0.cachePolicy != .volatile }
        }
        pressure.reset()
    }
}
