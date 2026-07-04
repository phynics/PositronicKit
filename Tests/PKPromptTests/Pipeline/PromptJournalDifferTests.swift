@testable import PKPrompt
import PKShared
import Testing

@Suite("PromptJournalDiffer")
struct PromptJournalDifferTests {
    private func stableSection(id: String, text: String, priority: Int = 100) -> RenderedPrompt.Section {
        RenderedPrompt.Section(
            id: id,
            role: .system,
            priority: priority,
            estimatedTokens: text.count,
            compression: .keep,
            type: .text,
            cachePolicy: .stable,
            path: ["prompt", "base", "stable", id],
            parentID: nil,
            content: .text(text)
        )
    }

    @Test("Reordering the same stable sections does not require a hard reset")
    func reorderedStableSectionsDoNotTriggerHardReset() {
        let sectionA = stableSection(id: "alpha", text: "Alpha content")
        let sectionB = stableSection(id: "beta", text: "Beta content")

        let committedBase = [sectionA, sectionB]
        let currentReordered = [sectionB, sectionA]

        let evaluation = PromptJournalDiffer.evaluate(
            committedBaseSections: committedBase,
            currentSections: currentReordered
        )

        #expect(evaluation.requiresHardReset == false)
    }

    @Test("Changing content of a stable section still requires a hard reset")
    func changedStableSectionContentTriggersHardReset() {
        let sectionA = stableSection(id: "alpha", text: "Alpha content")
        let sectionB = stableSection(id: "beta", text: "Beta content")

        let committedBase = [sectionA, sectionB]
        let currentChanged = [sectionB, stableSection(id: "alpha", text: "Alpha content CHANGED")]

        let evaluation = PromptJournalDiffer.evaluate(
            committedBaseSections: committedBase,
            currentSections: currentChanged
        )

        #expect(evaluation.requiresHardReset)
    }

    @Test("Adding a new stable section still requires a hard reset")
    func addedStableSectionTriggersHardReset() {
        let sectionA = stableSection(id: "alpha", text: "Alpha content")
        let sectionB = stableSection(id: "beta", text: "Beta content")
        let sectionC = stableSection(id: "gamma", text: "Gamma content")

        let committedBase = [sectionA, sectionB]
        let currentWithAddition = [sectionB, sectionA, sectionC]

        let evaluation = PromptJournalDiffer.evaluate(
            committedBaseSections: committedBase,
            currentSections: currentWithAddition
        )

        #expect(evaluation.requiresHardReset)
    }

    @Test("Removing a stable section still requires a hard reset")
    func removedStableSectionTriggersHardReset() {
        let sectionA = stableSection(id: "alpha", text: "Alpha content")
        let sectionB = stableSection(id: "beta", text: "Beta content")

        let committedBase = [sectionA, sectionB]
        let currentWithRemoval = [sectionB]

        let evaluation = PromptJournalDiffer.evaluate(
            committedBaseSections: committedBase,
            currentSections: currentWithRemoval
        )

        #expect(evaluation.requiresHardReset)
    }
}
