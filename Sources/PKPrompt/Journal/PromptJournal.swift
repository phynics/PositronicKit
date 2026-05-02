import Foundation

public struct PromptJournal: Sendable {
    private var committedBaseSections: [RenderedPrompt.Section] = []
    private var latestObservedSections: [RenderedPrompt.Section] = []

    public init() {}

    public mutating func observe(_ prompt: RenderedPrompt) -> PromptJournalPlan {
        let currentSections = prompt.sections
        defer { latestObservedSections = currentSections }

        if committedBaseSections.isEmpty {
            committedBaseSections = currentSections.filter { $0.cachePolicy != .volatile }
            return makePlan(
                committedBaseSections: committedBaseSections,
                currentSections: currentSections,
                overlaySections: [],
                requiresHardReset: false,
                diff: PromptJournalDiff()
            )
        }

        if hasStableChanges(comparedTo: currentSections) {
            committedBaseSections = currentSections.filter { $0.cachePolicy != .volatile }
            return makePlan(
                committedBaseSections: committedBaseSections,
                currentSections: currentSections,
                overlaySections: [],
                requiresHardReset: true,
                diff: PromptJournalDiff()
            )
        }

        let overlay = computeSemiStableOverlay(currentSections: currentSections)
        return makePlan(
            committedBaseSections: committedBaseSections,
            currentSections: currentSections,
            overlaySections: overlay.sections,
            requiresHardReset: false,
            diff: overlay.diff
        )
    }

    public mutating func compact() -> PromptJournalPlan? {
        guard !latestObservedSections.isEmpty else {
            return nil
        }

        committedBaseSections = latestObservedSections.filter { $0.cachePolicy != .volatile }
        return makePlan(
            committedBaseSections: committedBaseSections,
            currentSections: latestObservedSections,
            overlaySections: [],
            requiresHardReset: false,
            diff: PromptJournalDiff()
        )
    }

    public mutating func reset(hard: Bool = false) {
        latestObservedSections = []
        if hard {
            committedBaseSections = []
        }
    }

    private func hasStableChanges(comparedTo currentSections: [RenderedPrompt.Section]) -> Bool {
        let committedStable = committedBaseSections.filter { $0.cachePolicy == .stable }
        let currentStable = currentSections.filter { $0.cachePolicy == .stable }
        return stableSignature(for: committedStable) != stableSignature(for: currentStable)
    }

    private func stableSignature(for sections: [RenderedPrompt.Section]) -> [SectionSignature] {
        sections.map(SectionSignature.init)
    }

    private func computeSemiStableOverlay(
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

        let removed = committed
            .map(\.id)
            .filter { currentByID[$0] == nil }

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

    private func makePlan(
        committedBaseSections: [RenderedPrompt.Section],
        currentSections: [RenderedPrompt.Section],
        overlaySections: [RenderedPrompt.Section],
        requiresHardReset: Bool,
        diff: PromptJournalDiff
    ) -> PromptJournalPlan {
        PromptJournalPlan(
            baseSections: committedBaseSections.map { section in
                let normalizedPath = normalizedPolicyPath(for: section.path)
                return JournaledPromptSection(
                    section: section,
                    layer: .base,
                    sourcePath: section.path,
                    journalPath: ["prompt", "base"] + normalizedPath
                )
            },
            overlaySections: overlaySections.map { section in
                let normalizedPath = normalizedPolicyPath(for: section.path)
                return JournaledPromptSection(
                    section: section,
                    layer: .overlay,
                    sourcePath: section.path,
                    journalPath: ["prompt", "overlay"] + normalizedPath
                )
            },
            volatileSections: currentSections.filter { $0.cachePolicy == .volatile }.map { section in
                JournaledPromptSection(
                    section: section,
                    layer: .volatile,
                    sourcePath: section.path,
                    journalPath: ["prompt"] + normalizedPolicyPath(for: section.path)
                )
            },
            requiresHardReset: requiresHardReset,
            diff: diff
        )
    }

    private func normalizedPolicyPath(for path: [String]) -> ArraySlice<String> {
        if let index = path.lastIndex(where: { $0 == "stable" || $0 == "semiStable" || $0 == "volatile" }) {
            return path[index...]
        }
        return ArraySlice(path.dropFirst())
    }
}
