import Testing
@testable import PKPrompt

@Suite("PromptJournal")
struct PromptJournalTests {
    private func renderPrompt(system: String, context: String, query: String) async -> AssembledPrompt.RenderedPrompt {
        let prompt = try! AnyPrompt.build {
            SystemPrompt(system)
            TextPrompt(context, id: "context", cachePolicy: .semiStable)
            UserPrompt(query)
        }.assemblePrompt()

        return await prompt.render()
    }

    @Test("Initial observation materializes stable and semistable base while volatile stays current")
    func initialObservationBuildsBaseAndVolatileLayers() async {
        var journal = PromptJournal()
        let rendered = await renderPrompt(system: "System v1", context: "Context v1", query: "Question")

        let plan = journal.observe(rendered)

        #expect(plan.requiresHardReset == false)
        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.overlaySections.isEmpty)
        #expect(plan.volatileSections.map(\.section.id) == ["user_query"])
        #expect(plan.baseSections.map(\.layer) == [.base, .base])
        #expect(plan.volatileSections.map(\.layer) == [.volatile])
        #expect(plan.baseSections.map(\.journalPath) == [
            ["prompt", "base", "stable", "system"],
            ["prompt", "base", "semiStable", "context"],
        ])
        #expect(plan.volatileSections.map(\.journalPath) == [["prompt", "volatile", "user_query"]])
    }

    @Test("Semistable changes become overlay without mutating committed base")
    func semistableChangesCreateOverlay() async {
        var journal = PromptJournal()
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        let plan = journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

        #expect(plan.requiresHardReset == false)
        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.baseSections[1].renderedText == "Context v1")
        #expect(plan.overlaySections.map(\.section.id) == ["context"])
        #expect(plan.overlaySections[0].renderedText == "Context v2")
        #expect(plan.overlaySections[0].layer == .overlay)
        #expect(plan.overlaySections[0].journalPath == ["prompt", "overlay", "semiStable", "context"])
        #expect(plan.volatileSections.map(\.section.id) == ["user_query"])
    }

    @Test("Compaction promotes latest semistable state into base and clears overlay")
    func compactionPromotesOverlayIntoBase() async {
        var journal = PromptJournal()
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v2", query: "Question"))

        let compacted = journal.compact()

        #expect(compacted != nil)
        #expect(compacted?.overlaySections.isEmpty == true)
        #expect(compacted?.baseSections.map(\.section.id) == ["system", "context"])
        #expect(compacted?.baseSections[1].renderedText == "Context v2")
        #expect(compacted?.volatileSections.map(\.section.id) == ["user_query"])
    }

    @Test("Volatile changes never enter the committed base")
    func volatileChangesStayOutOfBase() async {
        var journal = PromptJournal()
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question 1"))

        let plan = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question 2"))

        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.overlaySections.isEmpty)
        #expect(plan.volatileSections.map(\.section.id) == ["user_query"])
        #expect(plan.volatileSections[0].renderedText == "Question 2")
    }

    @Test("Stable changes require hard reset")
    func stableChangesRequireHardReset() async {
        var journal = PromptJournal()
        _ = journal.observe(await renderPrompt(system: "System v1", context: "Context v1", query: "Question"))

        let plan = journal.observe(await renderPrompt(system: "System v2", context: "Context v1", query: "Question"))

        #expect(plan.requiresHardReset)
        #expect(plan.overlaySections.isEmpty)
        #expect(plan.baseSections.map(\.section.id) == ["system", "context"])
        #expect(plan.baseSections[0].renderedText == "System v2")
    }
}

private extension JournaledPromptSection {
    var renderedText: String? {
        section.content.text
    }
}
