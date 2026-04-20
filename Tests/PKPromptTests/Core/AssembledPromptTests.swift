import Foundation
import Testing
@testable import PKPrompt
import PKShared

private struct DummyPromptSection: PromptLeaf {
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

@Suite("AssembledPrompt")
struct AssembledPromptTests {
    @Test("Assembled prompt sorts resolved sections by priority descending")
    func initializationSortsByPriorityDesc() async {
        let sec1 = DummyPromptSection(id: "s1", priority: 1, estimatedTokens: 10, text: "Low")
        let sec2 = DummyPromptSection(id: "s2", priority: 100, estimatedTokens: 10, text: "High")

        let prompt = try! AssembledPrompt(resolvedSections: [sec1.resolve()[0], sec2.resolve()[0]])
        let resolved = prompt.resolvedSections

        #expect(resolved.count == 2)
        #expect(resolved[0].id == "s2")
        #expect(resolved[1].id == "s1")
    }

    @Test("Assembled prompt builds canonical ordered string")
    func buildString() async {
        let prompt = try! AssembledPrompt(resolvedSections: [
            DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 10, text: "First block").resolve()[0],
            DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 10, text: nil).resolve()[0],
            DummyPromptSection(id: "s3", priority: 1, estimatedTokens: 10, text: "Second block").resolve()[0],
        ])

        let rendered = await prompt.buildString()
        #expect(rendered == "First block\n\n---\n\nSecond block")
    }

    @Test("Assembled prompt snapshot skips empty content")
    func renderedSectionsByID() async {
        let prompt = try! AssembledPrompt(resolvedSections: [
            DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 10, text: "Val1").resolve()[0],
            DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 10, text: "").resolve()[0],
            DummyPromptSection(id: "s3", priority: 1, estimatedTokens: 10, text: "Val2").resolve()[0],
        ])

        let rendered = await prompt.buildSectionsByID()
        #expect(rendered.count == 2)
        #expect(rendered["s1"] == "Val1")
        #expect(rendered["s3"] == "Val2")
        #expect(rendered["s2"] == nil)
    }

    @Test("Assembled prompt snapshot preserves history as message content")
    func renderedHistoryUsesMessageContent() async {
        let messages = [
            Message(content: "Hello", role: .user),
            Message(content: "Hi", role: .assistant),
        ]
        let prompt = try! AssembledPrompt(resolvedSections: [
            HistorySection(messages: messages).resolve()[0],
        ])

        let rendered = await prompt.buildSections()

        #expect(rendered.count == 1)
        #expect(rendered[0].content == RenderedPromptSectionContent.messages(messages))
    }

    @Test("Dropped history sections do not survive rendered snapshots")
    func droppedHistoryDoesNotRender() async {
        let droppedHistory = HistorySection(messages: [
            Message(content: "Hello", role: .user),
        ]).resolve()[0].dropped()
        let prompt = try! AssembledPrompt(resolvedSections: [droppedHistory])

        let rendered = await prompt.buildSections()

        #expect(rendered.isEmpty)
        #expect(await prompt.buildString().isEmpty)
    }

    @Test("Assembled prompt estimatedTokens sums resolved tokens")
    func estimatedTokens() {
        let prompt = try! AssembledPrompt(resolvedSections: [
            DummyPromptSection(id: "s1", priority: 10, estimatedTokens: 50, text: "A").resolve()[0],
            DummyPromptSection(id: "s2", priority: 5, estimatedTokens: 100, text: "B").resolve()[0],
        ])

        #expect(prompt.estimatedTokens == 150)
    }

    @Test("Assembled prompt sorts by cache policy before priority")
    func cachePolicySorting() async {
        let volatileHigh = DummyPromptSection(id: "volatileHigh", priority: 100, estimatedTokens: 0, text: "V", cachePolicy: .volatile)
        let semiStableLow = DummyPromptSection(id: "semiStableLow", priority: 1, estimatedTokens: 0, text: "S", cachePolicy: .semiStable)
        let stableMedium = DummyPromptSection(id: "stableMedium", priority: 50, estimatedTokens: 0, text: "M", cachePolicy: .stable)
        let stableHigh = DummyPromptSection(id: "stableHigh", priority: 100, estimatedTokens: 0, text: "H", cachePolicy: .stable)

        let prompt = try! AssembledPrompt(resolvedSections: [
            volatileHigh.resolve()[0],
            semiStableLow.resolve()[0],
            stableMedium.resolve()[0],
            stableHigh.resolve()[0],
        ])
        let resolved = prompt.resolvedSections

        #expect(resolved.map { $0.id } == ["stableHigh", "stableMedium", "semiStableLow", "volatileHigh"])
    }

    @Test("Assembled prompt rejects multiple user query sections")
    func multipleUserQueriesAreRejected() {
        let query1 = DummyPromptSection(id: "q1", priority: 10, estimatedTokens: 5, text: "One")
        let query2 = DummyPromptSection(id: "q2", priority: 5, estimatedTokens: 5, text: "Two")

        #expect(throws: PromptSectionValidationError.multipleUserQuerySections(["q1", "q2"])) {
            try AssembledPrompt(resolvedSections: [
                ResolvedPromptSection(
                    id: query1.id,
                    role: .userQuery,
                    priority: query1.priority,
                    estimatedTokens: query1.estimatedTokens,
                    compression: .keep,
                    type: .text,
                    cachePolicy: query1.cachePolicy,
                    path: [query1.id],
                    render: { _ in
                        query1.text.map(RenderedPromptSectionContent.text)
                    }
                ),
                ResolvedPromptSection(
                    id: query2.id,
                    role: .userQuery,
                    priority: query2.priority,
                    estimatedTokens: query2.estimatedTokens,
                    compression: .keep,
                    type: .text,
                    cachePolicy: query2.cachePolicy,
                    path: [query2.id],
                    render: { _ in
                        query2.text.map(RenderedPromptSectionContent.text)
                    }
                ),
            ])
        }
    }
}
