import Testing
@testable import PKPrompt

@Suite("StructuredCompressionPlanner")
struct StructuredCompressionPlannerTests {
    @Test("Prioritizes changed volatile sections over stable sections")
    func prioritizesChangedSubtrees() {
        let planner = StructuredCompressionPlanner()
        let nodes: [StructuredCompressionNode] = [
            .init(id: "system", path: ["prompt", "stable", "system"], nodeHash: 1, priority: 10, cachePolicy: .stable, strategy: .summarize, estimatedTokens: 400),
            .init(id: "history", path: ["prompt", "volatile", "history"], nodeHash: 2, priority: 3, cachePolicy: .volatile, strategy: .summarize, estimatedTokens: 500),
        ]

        let diff = StructuredDiffHint(
            changedNodePaths: [["prompt", "volatile", "history"]],
            stableNodePaths: [["prompt", "stable", "system"]]
        )

        let plan = try! planner.plan(nodes: nodes, availableTokens: 450, diff: diff)

        let history = plan.nodeActions.first { $0.nodeId == "history" }
        let system = plan.nodeActions.first { $0.nodeId == "system" }
        #expect(history != nil)
        #expect(system != nil)
        #expect(history?.action != .drop)
        #expect(system?.action == .drop)
    }

    @Test("Produces deterministic output order")
    func deterministicOrder() {
        let planner = StructuredCompressionPlanner()
        let nodes: [StructuredCompressionNode] = [
            .init(id: "b", path: ["prompt", "volatile", "b"], nodeHash: 2, priority: 1, cachePolicy: .volatile, strategy: .drop, estimatedTokens: 100),
            .init(id: "a", path: ["prompt", "volatile", "a"], nodeHash: 1, priority: 1, cachePolicy: .volatile, strategy: .drop, estimatedTokens: 100),
        ]

        let first = try! planner.plan(nodes: nodes, availableTokens: 100, diff: nil)
        let second = try! planner.plan(nodes: nodes, availableTokens: 100, diff: nil)
        #expect(first.nodeActions.map(\.nodeId) == second.nodeActions.map(\.nodeId))
        #expect(first.nodeActions.map(\.action) == second.nodeActions.map(\.action))
    }
}
