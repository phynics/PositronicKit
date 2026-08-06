import PKPrompt
import PositronicKitExamples
import Testing

@Suite("Introductory stories")
struct IntroductoryStoriesTests {
    @Test("Prompt journaling example shows base overlay and compaction flow")
    func promptJournalingExample() async throws {
        var journal = PromptJournal()

        let initial = try await (PKPromptExamples.makeStableToolingPrompt(
            tools: [
                .init(id: "build", summary: "Builds the package."),
                .init(id: "test", summary: "Runs the test suite."),
            ],
            userQuery: "What should I run first?"
        ).assemblePrompt()).render()

        let updated = try await (PKPromptExamples.makeStableToolingPrompt(
            tools: [
                .init(id: "build", summary: "Builds the package."),
                .init(id: "test", summary: "Runs the full test suite."),
                .init(id: "lint", summary: "Checks formatting and style."),
            ],
            userQuery: "What should I run first?"
        ).assemblePrompt()).render()

        let initialPlan = journal.observe(initial)
        #expect(initialPlan.baseSections.map(\.section.id) == ["system", "tool-build", "tool-test"])
        #expect(initialPlan.overlaySections.isEmpty)
        #expect(initialPlan.volatileSections.map(\.section.id) == ["user_query"])

        let updatedPlan = journal.observe(updated)
        #expect(updatedPlan.baseSections.map(\.section.id) == ["system", "tool-build", "tool-test"])
        #expect(updatedPlan.overlaySections.map(\.section.id) == ["tool-test", "tool-lint"])
        #expect(updatedPlan.overlaySections.allSatisfy { $0.layer == .overlay })

        let compacted = journal.compact()
        #expect(compacted?.overlaySections.isEmpty == true)
        #expect(compacted?.baseSections.map(\.section.id) == ["system", "tool-build", "tool-test", "tool-lint"])
    }
}
