import Foundation
import Testing
@testable import PKPrompt
import PKShared

private struct DummyPromptSection: PromptPrimitive {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let text: String?
    let cachePolicy: CachePolicy

    init(
        id: String,
        priority: Int,
        estimatedTokens: Int,
        text: String?,
        cachePolicy: CachePolicy = .volatile
    ) {
        self.id = id
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.text = text
        self.cachePolicy = cachePolicy
    }

    func renderContent() async -> String? {
        text
    }
}

private func resolved(_ section: DummyPromptSection) -> AssembledPrompt.Section {
    section.assembleSections()[0]
}

private func historySection(_ messages: [Message]) -> AssembledPrompt.Section {
    try! HistoryPrompt(messages).assemblePrompt().sections[0]
}

@Suite("AssembledPrompt")
struct AssembledPromptTests {
    @Test("Assembled prompt sorts resolved sections by priority descending")
    func initializationSortsByPriorityDesc() {
        let sec1 = DummyPromptSection(id: "s1", priority: 1, estimatedTokens: 10, text: "Low")
        let sec2 = DummyPromptSection(id: "s2", priority: 100, estimatedTokens: 10, text: "High")

        let prompt = try! AssembledPrompt(sections: [resolved(sec1), resolved(sec2)])
        #expect(prompt.sections.map(\.id) == ["s2", "s1"])
    }

    @Test("Assembled prompt builds canonical ordered string")
    func buildString() async {
        let prompt = try! AssembledPrompt(sections: [
            resolved(DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 10, text: "First block")),
            resolved(DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 10, text: nil)),
            resolved(DummyPromptSection(id: "s3", priority: 1, estimatedTokens: 10, text: "Second block")),
        ])

        let rendered = await prompt.render()
        #expect(rendered.string == "First block\n\n---\n\nSecond block")
    }

    @Test("Assembled prompt snapshot skips empty content")
    func renderedSectionsByID() async {
        let prompt = try! AssembledPrompt(sections: [
            resolved(DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 10, text: "Val1")),
            resolved(DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 10, text: "")),
            resolved(DummyPromptSection(id: "s3", priority: 1, estimatedTokens: 10, text: "Val2")),
        ])

        let rendered = await prompt.render()
        #expect(rendered.sectionsByID.count == 2)
        #expect(rendered.sectionsByID["s1"] == "Val1")
        #expect(rendered.sectionsByID["s3"] == "Val2")
        #expect(rendered.sectionsByID["s2"] == nil)
    }

    @Test("Assembled prompt snapshot preserves history as message content")
    func renderedHistoryUsesMessageContent() async {
        let messages = [
            Message(content: "Hello", role: .user),
            Message(content: "Hi", role: .assistant),
        ]
        let prompt = try! AssembledPrompt(sections: [historySection(messages)])

        let rendered = await prompt.render()
        #expect(rendered.sections.count == 1)
        #expect(rendered.sections[0].content == AssembledPrompt.Section.Content.messages(messages))
    }

    @Test("Assembled prompt renders a canonical product from one pass")
    func renderedProductIncludesHistorySnapshots() async {
        let messages = [
            Message(content: "Hello", role: .user),
            Message(content: "Hi", role: .assistant),
        ]
        let prompt = try! AssembledPrompt(sections: [
            resolved(DummyPromptSection(id: "system", priority: 100, estimatedTokens: 10, text: "Rules")),
            historySection(messages),
        ])

        let rendered = await prompt.render()

        #expect(rendered.sections.count == 2)
        #expect(rendered.string == "Rules\n\n---\n\nUser: Hello\n\nAssistant: Hi")
        #expect(rendered.sectionsByID["system"] == "Rules")
        #expect(rendered.sectionsByID["chat_history"] == "User: Hello\n\nAssistant: Hi")
    }

    @Test("Dropped history sections do not survive rendered snapshots")
    func droppedHistoryDoesNotRender() async {
        let droppedHistory = historySection([Message(content: "Hello", role: .user)]).dropped()
        let prompt = try! AssembledPrompt(sections: [droppedHistory])

        let rendered = await prompt.render()
        #expect(rendered.sections.isEmpty)
        #expect(rendered.string.isEmpty)
    }

    @Test("Rendered sections preserve compression outcome metadata")
    func renderedSectionsPreserveCompressionOutcome() async {
        let report = CompressionNodeReport(
            nodeId: "s1",
            path: ["prompt", "s1"],
            action: .summarize(targetTokens: 10, reason: .budgetReduction),
            beforeTokens: 50,
            afterTokens: 10,
            cacheHit: false,
            fallbackReason: nil
        )
        let prompt = try! AssembledPrompt(sections: [
            AssembledPrompt.Section(
                id: "s1",
                role: .context,
                priority: 10,
                estimatedTokens: 10,
                compression: .summarize,
                type: .text,
                cachePolicy: .volatile,
                path: ["prompt", "s1"],
                compressionOutcome: report,
                render: { _ in .text("summary") }
            )
        ], compressionReport: CompressionReport(nodeReports: [report]))

        let rendered = await prompt.render()
        #expect(rendered.sections.count == 1)
        #expect(rendered.sections[0].compression == .summarize)
        #expect(rendered.sections[0].compressionOutcome == report)
        #expect(rendered.compressionReport?.nodeReports == [report])
    }

    @Test("Assembled prompt estimatedTokens sums resolved tokens")
    func estimatedTokens() {
        let prompt = try! AssembledPrompt(sections: [
            resolved(DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 50, text: "A")),
            resolved(DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 100, text: "B")),
        ])

        #expect(prompt.estimatedTokens == 150)
    }

    @Test("Assembled prompt sorts by cache policy before priority")
    func cachePolicySorting() {
        let volatileHigh = DummyPromptSection(id: "volatileHigh", priority: 100, estimatedTokens: 0, text: "V", cachePolicy: .volatile)
        let semiStableLow = DummyPromptSection(id: "semiStableLow", priority: 1, estimatedTokens: 0, text: "S", cachePolicy: .semiStable)
        let stableMedium = DummyPromptSection(id: "stableMedium", priority: 50, estimatedTokens: 0, text: "M", cachePolicy: .stable)
        let stableHigh = DummyPromptSection(id: "stableHigh", priority: 100, estimatedTokens: 0, text: "H", cachePolicy: .stable)

        let prompt = try! AssembledPrompt(sections: [
            resolved(volatileHigh),
            resolved(semiStableLow),
            resolved(stableMedium),
            resolved(stableHigh),
        ])

        #expect(prompt.sections.map(\.id) == ["stableHigh", "stableMedium", "semiStableLow", "volatileHigh"])
    }

    @Test("Assembled prompt rejects multiple user query sections")
    func multipleUserQueriesAreRejected() {
        let query1 = DummyPromptSection(id: "q1", priority: 10, estimatedTokens: 5, text: "One")
        let query2 = DummyPromptSection(id: "q2", priority: 5, estimatedTokens: 5, text: "Two")

        #expect(throws: AssembledPrompt.ValidationError.multipleUserQuerySections(["q1", "q2"])) {
            try AssembledPrompt(sections: [
                AssembledPrompt.Section(
                    id: query1.id,
                    role: .userQuery,
                    priority: query1.priority,
                    estimatedTokens: query1.estimatedTokens,
                    compression: .keep,
                    type: .text,
                    cachePolicy: query1.cachePolicy,
                    path: [query1.id],
                    render: { _ in query1.text.map(AssembledPrompt.Section.Content.text) }
                ),
                AssembledPrompt.Section(
                    id: query2.id,
                    role: .userQuery,
                    priority: query2.priority,
                    estimatedTokens: query2.estimatedTokens,
                    compression: .keep,
                    type: .text,
                    cachePolicy: query2.cachePolicy,
                    path: [query2.id],
                    render: { _ in query2.text.map(AssembledPrompt.Section.Content.text) }
                ),
            ])
        }
    }
}
