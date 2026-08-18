import Foundation
import Testing
@testable import PKPrompt

@Suite("PKPrompt API fluency")
struct PKPromptAPIFluencyTests {
    @Test("Canonical truncation retention maps to the compatible Boolean payload")
    func canonicalTruncationRetention() {
        #expect(CompressionStrategy.truncate(keeping: .head) == .truncate(tail: true))
        #expect(CompressionStrategy.truncate(keeping: .tail) == .truncate(tail: false))
        #expect(CompressionAction.truncate(limit: 12, keeping: .head) == .truncate(limit: 12, tail: true))
        #expect(CompressionAction.truncate(limit: 12, keeping: .tail) == .truncate(limit: 12, tail: false))
    }

    @Test("Canonical truncation keeps the legacy wire representation")
    func truncationWireCompatibility() throws {
        let strategy = CompressionStrategy.truncate(keeping: .head)
        let action = CompressionAction.truncate(limit: 12, keeping: .tail)

        #expect(try jsonDictionary(strategy).isEqual(to: ["truncate": ["tail": true]]))
        #expect(try jsonDictionary(action).isEqual(to: ["truncate": ["limit": 12, "tail": false]]))

        let decodedStrategy = try JSONDecoder().decode(
            CompressionStrategy.self,
            from: Data(#"{"truncate":{"tail":false}}"#.utf8)
        )
        let decodedAction = try JSONDecoder().decode(
            CompressionAction.self,
            from: Data(#"{"truncate":{"limit":9,"tail":true}}"#.utf8)
        )
        #expect(decodedStrategy == .truncate(keeping: .tail))
        #expect(decodedAction == .truncate(limit: 9, keeping: .head))
    }

    @Test("Resetting an observation retains the committed base")
    func resetObservationRetainsCommittedBase() async {
        var journal = PromptJournal(state: journalState())

        journal.resetKeepingCommittedState()

        #expect(journal.state.committedBaseSections.count == 1)
        #expect(journal.state.latestObservedSections.isEmpty)
        #expect(journal.state.appendedMessageCount == 0)
        #expect(journal.state.appendedTokens == 0)
    }

    @Test("Discarding journal state removes the committed base")
    func resetDiscardingCommittedState() async {
        var journal = PromptJournal(state: journalState())

        journal.resetDiscardingCommittedState()

        #expect(journal.state.committedBaseSections.isEmpty)
        #expect(journal.state.latestObservedSections.isEmpty)
        #expect(journal.state.appendedMessageCount == 0)
        #expect(journal.state.appendedTokens == 0)
    }

    @Test("ForEach canonical initializer builds every element")
    func canonicalForEachInitializer() {
        let prompt = ForEach(["one", "two"]) { element in
            TextPrompt(element, id: element)
        }

        #expect(prompt.makePromptNode() != nil)
    }

    @Test("Token budget result is the canonical structured projection")
    func canonicalTokenBudgetResult() async throws {
        let sections: [any Prompt] = [TextPrompt("hello", id: "greeting")]

        let result = try await TokenBudget(maxTokens: 20).result(forPrompts: sections)

        #expect(result.sections.map(\.id) == ["greeting"])
        #expect(result.report == nil)
        #expect(result.estimatedTokens <= result.availableTokens)
    }

    @Test("Token budget result domains remain clear for empty arrays")
    func canonicalTokenBudgetEmptyArrays() async throws {
        let budget = TokenBudget(maxTokens: 20)

        let promptResult = try await budget.result(forPrompts: [])
        let sectionResult = try await budget.result(forResolvedSections: [])

        #expect(promptResult.sections.isEmpty)
        #expect(sectionResult.sections.isEmpty)
    }

    @Test("Canonical node ID properties retain the nodeId wire key")
    func canonicalNodeIDWireCompatibility() throws {
        let report = CompressionNodeReport(
            nodeID: "node-1",
            path: ["prompt", "node-1"],
            action: .keep,
            beforeTokens: 4,
            afterTokens: 4,
            cacheHit: false,
            fallbackReason: nil
        )
        let request = SummaryRequest(
            nodeID: "node-1",
            path: ["prompt", "node-1"],
            text: "text",
            targetTokens: 2,
            reason: .budgetReduction
        )
        let planned = PlannedNodeAction(
            nodeID: "node-1",
            path: ["prompt", "node-1"],
            nodeHash: 1,
            strategy: .keep,
            estimatedTokens: 4,
            action: .keep
        )

        let object = try jsonDictionary(report)
        #expect(object["nodeId"] as? String == "node-1")
        #expect(object["nodeID"] == nil)
        #expect(report.nodeID == "node-1")
        #expect(request.nodeID == "node-1")
        #expect(planned.nodeID == "node-1")

        let decoded = try JSONDecoder().decode(
            CompressionNodeReport.self,
            from: JSONEncoder().encode(report)
        )
        #expect(decoded.nodeID == "node-1")
    }
}

@Suite("PKPrompt compatibility shims")
struct PKPromptCompatibilityShimTests {
    @Test("Legacy token-budget methods project the canonical result")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func legacyTokenBudgetForwarding() async throws {
        let sections: [any Prompt] = [TextPrompt("hello", id: "greeting")]
        let budget = TokenBudget(maxTokens: 20)

        let applied = try await budget.apply(to: sections)
        let reported = try await budget.applyWithReport(to: sections)
        let budgeted = try await budget.budget(to: sections)

        #expect(applied.map(\.id) == ["greeting"])
        #expect(reported.sections.map(\.id) == ["greeting"])
        #expect(reported.report == nil)
        #expect(budgeted.sections.map(\.id) == ["greeting"])
    }

    @Test("Legacy reset forwards to explicit reset operations")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func legacyResetForwarding() {
        var soft = PromptJournal(state: journalState())
        var hard = PromptJournal(state: journalState())

        soft.reset(hard: false)
        hard.reset(hard: true)

        #expect(soft.state.committedBaseSections.count == 1)
        #expect(hard.state.committedBaseSections.isEmpty)
    }

    @Test("Legacy nodeId initializers and properties forward to nodeID")
    @available(*, deprecated, message: "Intentional legacy API compatibility coverage.")
    func legacyNodeIDForwarding() {
        let report = CompressionNodeReport(
            nodeId: "legacy",
            path: [],
            action: .keep,
            beforeTokens: 1,
            afterTokens: 1,
            cacheHit: false,
            fallbackReason: nil
        )
        let request = SummaryRequest(
            nodeId: "legacy",
            path: [],
            text: "text",
            targetTokens: 1,
            reason: .budgetReduction
        )
        let planned = PlannedNodeAction(
            nodeId: "legacy",
            path: [],
            nodeHash: 1,
            strategy: .keep,
            estimatedTokens: 1,
            action: .keep
        )

        #expect(report.nodeId == report.nodeID)
        #expect(request.nodeId == request.nodeID)
        #expect(planned.nodeId == planned.nodeID)
    }
}

private func journalState() -> PromptJournal.State {
    let section = RenderedPrompt.Section(
        id: "base",
        role: .system,
        priority: PromptPriority.critical.rawValue,
        estimatedTokens: 1,
        compression: .keep,
        type: .text,
        cachePolicy: .stable,
        path: ["prompt", "stable", "base"],
        parentID: nil,
        content: .text("base")
    )
    return PromptJournal.State(
        committedBaseSections: [section],
        latestObservedSections: [section],
        appendedMessageCount: 2,
        appendedTokens: 3,
        thresholds: .default
    )
}

private func jsonDictionary<T: Encodable>(_ value: T) throws -> NSDictionary {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    return try #require(object as? NSDictionary)
}
