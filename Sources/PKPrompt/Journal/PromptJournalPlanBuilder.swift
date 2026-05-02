import Foundation

/// Projects evaluated journal state into a concrete ``PromptJournalPlan``.
///
/// This helper owns journal-path normalization so `PromptJournal` stays focused on lifecycle and
/// state transitions.
package enum PromptJournalPlanBuilder {
    /// Builds the journal plan for the current observation.
    package static func makePlan(
        committedBaseSections: [RenderedPrompt.Section],
        currentSections: [RenderedPrompt.Section],
        overlaySections: [RenderedPrompt.Section],
        requiresHardReset: Bool,
        diff: PromptJournalDiff,
        emissionMode: PromptJournalPlan.EmissionMode
    ) -> PromptJournalPlan {
        PromptJournalPlan(
            baseSections: committedBaseSections.map { journaledSection($0, layer: .base, root: ["prompt", "base"]) },
            overlaySections: overlaySections.map { journaledSection($0, layer: .overlay, root: ["prompt", "overlay"]) },
            volatileSections: currentSections
                .filter { $0.cachePolicy == .volatile }
                .map { journaledSection($0, layer: .volatile, root: ["prompt"]) },
            requiresHardReset: requiresHardReset,
            diff: diff,
            emissionMode: emissionMode
        )
    }

    private static func journaledSection(
        _ section: RenderedPrompt.Section,
        layer: JournaledPromptSection.JournalLayer,
        root: [String]
    ) -> JournaledPromptSection {
        JournaledPromptSection(
            section: section,
            layer: layer,
            sourcePath: section.path,
            journalPath: root + normalizedPolicyPath(for: section.path)
        )
    }

    private static func normalizedPolicyPath(for path: [String]) -> ArraySlice<String> {
        if let index = path.lastIndex(where: { $0 == "stable" || $0 == "semiStable" || $0 == "volatile" }) {
            return path[index...]
        }
        return ArraySlice(path.dropFirst())
    }
}
