import Foundation

/// Computes journal diff policy for a newly rendered prompt.
///
/// This helper decides whether stable content requires a hard reset and which semistable sections
/// should be emitted as the current overlay.
package enum PromptJournalDiffer {
    /// Evaluates the current prompt against the committed journal base.
    package static func evaluate(
        committedBaseSections: [RenderedPrompt.Section],
        currentSections: [RenderedPrompt.Section]
    ) -> PromptJournalEvaluation {
        if committedBaseSections.isEmpty {
            return PromptJournalEvaluation(
                nextCommittedBaseSections: currentSections.filter { $0.cachePolicy != .volatile },
                overlaySections: [],
                requiresHardReset: false,
                diff: PromptJournalDiff(),
                emissionMode: .snapshot
            )
        }

        if hasStableChanges(
            committedBaseSections: committedBaseSections,
            currentSections: currentSections
        ) {
            return PromptJournalEvaluation(
                nextCommittedBaseSections: currentSections.filter { $0.cachePolicy != .volatile },
                overlaySections: [],
                requiresHardReset: true,
                diff: PromptJournalDiff(),
                emissionMode: .snapshot
            )
        }

        let overlay = computeSemiStableOverlay(
            committedBaseSections: committedBaseSections,
            currentSections: currentSections
        )
        return PromptJournalEvaluation(
            nextCommittedBaseSections: committedBaseSections,
            overlaySections: overlay.sections,
            requiresHardReset: false,
            diff: overlay.diff,
            emissionMode: .delta
        )
    }

    private static func hasStableChanges(
        committedBaseSections: [RenderedPrompt.Section],
        currentSections: [RenderedPrompt.Section]
    ) -> Bool {
        let committedStable = committedBaseSections.filter { $0.cachePolicy == .stable }
        let currentStable = currentSections.filter { $0.cachePolicy == .stable }
        return committedStable.map(SectionSignature.init) != currentStable.map(SectionSignature.init)
    }

    private static func computeSemiStableOverlay(
        committedBaseSections: [RenderedPrompt.Section],
        currentSections: [RenderedPrompt.Section]
    ) -> (sections: [RenderedPrompt.Section], diff: PromptJournalDiff) {
        let committed = committedBaseSections.filter { $0.cachePolicy == .semiStable }
        let current = currentSections.filter { $0.cachePolicy == .semiStable }

        let committedByID = Dictionary(uniqueKeysWithValues: committed.map { ($0.id, SectionSignature($0)) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, SectionSignature($0)) })

        var changed: [String] = []
        var added: [String] = []
        for section in current {
            if let committedSignature = committedByID[section.id] {
                if committedSignature != SectionSignature(section) {
                    changed.append(section.id)
                }
            } else {
                added.append(section.id)
            }
        }

        let removed = committed.map(\.id).filter { currentByID[$0] == nil }
        let overlayIDs = Set(changed + added)
        let overlaySections = current.filter { overlayIDs.contains($0.id) }

        return (
            overlaySections,
            PromptJournalDiff(
                changedSemiStableIDs: changed,
                addedSemiStableIDs: added,
                removedSemiStableIDs: removed
            )
        )
    }
}

/// Internal result describing how the journal state should advance for one observation.
package struct PromptJournalEvaluation {
    let nextCommittedBaseSections: [RenderedPrompt.Section]
    let overlaySections: [RenderedPrompt.Section]
    let requiresHardReset: Bool
    let diff: PromptJournalDiff
    let emissionMode: PromptJournalPlan.EmissionMode
}

/// Content fingerprint used when comparing rendered sections for journal diffing.
private struct SectionSignature: Equatable {
    let id: String
    let contentHash: Int
    let path: [String]
    let parentID: String?
    let estimatedTokens: Int
    let type: PromptSectionType

    init(_ section: RenderedPrompt.Section) {
        self.id = section.id
        self.contentHash = SectionSignature.hashContent(section.content)
        self.path = section.path
        self.parentID = section.parentID
        self.estimatedTokens = section.estimatedTokens
        self.type = section.type
    }

    private static func hashContent(_ content: PromptSection.Content) -> Int {
        var hasher = Hasher()
        switch content {
        case let .text(text):
            hasher.combine(0)
            hasher.combine(text)
        case let .messages(messages):
            hasher.combine(1)
            for message in messages {
                hasher.combine(message.content)
                hasher.combine(String(describing: message.role))
                hasher.combine(message.think)
                hasher.combine(message.isSummary)
            }
        }
        return hasher.finalize()
    }
}
