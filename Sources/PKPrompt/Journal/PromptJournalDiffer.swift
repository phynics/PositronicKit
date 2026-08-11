import Foundation

/// Computes journal diff policy for a newly rendered prompt.
///
/// This helper decides whether stable content requires a hard reset and which semistable sections
/// should be emitted as the current overlay.
package enum PromptJournalDiffer {
    /// Validates the section identifiers used by journal maps before any diffing occurs.
    package static func validate(_ sections: [RenderedPrompt.Section]) throws {
        let stableIDs = sections
            .filter { $0.cachePolicy == .stable }
            .duplicateIDs(idKeyPath: \.id)
        guard stableIDs.isEmpty else {
            throw PromptJournalValidationError.duplicateStableSectionIDs(stableIDs)
        }

        let semiStableIDs = sections
            .filter { $0.cachePolicy == .semiStable }
            .duplicateIDs(idKeyPath: \.id)
        guard semiStableIDs.isEmpty else {
            throw PromptJournalValidationError.duplicateSemiStableSectionIDs(semiStableIDs)
        }
    }

    /// Evaluates the current prompt against the committed journal base.
    package static func evaluate(
        committedBaseSections: [RenderedPrompt.Section],
        currentSections: [RenderedPrompt.Section]
    ) throws -> PromptJournalEvaluation {
        try validate(committedBaseSections)
        try validate(currentSections)

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

        let committedByID = Dictionary(
            uniqueKeysWithValues: committedStable.map { ($0.id, SectionSignature($0)) }
        )
        let currentByID = Dictionary(
            uniqueKeysWithValues: currentStable.map { ($0.id, SectionSignature($0)) }
        )
        return committedByID != currentByID
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
///
/// Per PKDEEP2-003 decision (b), the fingerprint is text-only: `estimatedTokens` and `type` are
/// excluded — a token-estimate delta with identical text is an estimator artifact, not real
/// cache-prefix invalidation. The hash is computed by the shared `sectionContentHash(_:)`
/// helper, which folds `role`/`think`/`isSummary` into `.messages` inputs so no content-bearing
/// change is lost.
private struct SectionSignature: Equatable {
    let id: String
    let contentHash: UInt64
    let path: [String]
    let parentID: String?

    init(_ section: RenderedPrompt.Section) {
        id = section.id
        contentHash = sectionContentHash(section.content)
        path = section.path
        parentID = section.parentID
    }
}
