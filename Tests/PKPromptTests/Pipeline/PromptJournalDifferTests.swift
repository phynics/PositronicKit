@testable import PKPrompt
import PKContracts
import PKUtilities
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
    func reorderedStableSectionsDoNotTriggerHardReset() throws {
        let sectionA = stableSection(id: "alpha", text: "Alpha content")
        let sectionB = stableSection(id: "beta", text: "Beta content")

        let committedBase = [sectionA, sectionB]
        let currentReordered = [sectionB, sectionA]

        let evaluation = try PromptJournalDiffer.evaluate(
            committedBaseSections: committedBase,
            currentSections: currentReordered
        )

        #expect(evaluation.requiresHardReset == false)
    }

    @Test("Changing content of a stable section still requires a hard reset")
    func changedStableSectionContentTriggersHardReset() throws {
        let sectionA = stableSection(id: "alpha", text: "Alpha content")
        let sectionB = stableSection(id: "beta", text: "Beta content")

        let committedBase = [sectionA, sectionB]
        let currentChanged = [sectionB, stableSection(id: "alpha", text: "Alpha content CHANGED")]

        let evaluation = try PromptJournalDiffer.evaluate(
            committedBaseSections: committedBase,
            currentSections: currentChanged
        )

        #expect(evaluation.requiresHardReset)
    }

    @Test("Adding a new stable section still requires a hard reset")
    func addedStableSectionTriggersHardReset() throws {
        let sectionA = stableSection(id: "alpha", text: "Alpha content")
        let sectionB = stableSection(id: "beta", text: "Beta content")
        let sectionC = stableSection(id: "gamma", text: "Gamma content")

        let committedBase = [sectionA, sectionB]
        let currentWithAddition = [sectionB, sectionA, sectionC]

        let evaluation = try PromptJournalDiffer.evaluate(
            committedBaseSections: committedBase,
            currentSections: currentWithAddition
        )

        #expect(evaluation.requiresHardReset)
    }

    @Test("Removing a stable section still requires a hard reset")
    func removedStableSectionTriggersHardReset() throws {
        let sectionA = stableSection(id: "alpha", text: "Alpha content")
        let sectionB = stableSection(id: "beta", text: "Beta content")

        let committedBase = [sectionA, sectionB]
        let currentWithRemoval = [sectionB]

        let evaluation = try PromptJournalDiffer.evaluate(
            committedBaseSections: committedBase,
            currentSections: currentWithRemoval
        )

        #expect(evaluation.requiresHardReset)
    }

    @Test("Token-only changes to a stable section do not trigger a hard reset")
    func tokenOnlyStableChangeDoesNotTriggerHardReset() throws {
        let sectionA = stableSection(id: "alpha", text: "Alpha content")
        let sectionAChangedTokens = RenderedPrompt.Section(
            id: "alpha",
            role: .system,
            priority: 100,
            estimatedTokens: 999,
            compression: .keep,
            type: .text,
            cachePolicy: .stable,
            path: ["prompt", "base", "stable", "alpha"],
            parentID: nil,
            content: .text("Alpha content")
        )

        let evaluation = try PromptJournalDiffer.evaluate(
            committedBaseSections: [sectionA],
            currentSections: [sectionAChangedTokens]
        )

        #expect(evaluation.requiresHardReset == false)
    }

    @Test("Token-only changes to a semistable section do not register as overlay changes")
    func tokenOnlySemistableChangeDoesNotRegisterAsOverlay() throws {
        let section = RenderedPrompt.Section(
            id: "semi-a",
            role: .system,
            priority: 100,
            estimatedTokens: 10,
            compression: .keep,
            type: .text,
            cachePolicy: .semiStable,
            path: ["prompt", "base", "semiStable", "semi-a"],
            parentID: nil,
            content: .text("Same text")
        )
        let sectionChangedTokens = RenderedPrompt.Section(
            id: "semi-a",
            role: .system,
            priority: 100,
            estimatedTokens: 999,
            compression: .keep,
            type: .text,
            cachePolicy: .semiStable,
            path: ["prompt", "base", "semiStable", "semi-a"],
            parentID: nil,
            content: .text("Same text")
        )

        let evaluation = try PromptJournalDiffer.evaluate(
            committedBaseSections: [section],
            currentSections: [sectionChangedTokens]
        )

        #expect(evaluation.requiresHardReset == false)
        #expect(evaluation.diff == PromptJournalDiff())
        #expect(evaluation.overlaySections.isEmpty)
    }
}
