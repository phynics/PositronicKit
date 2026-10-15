import Foundation

public extension TokenBudget {
    /// Applies this budget to unresolved declarative prompts and returns the verified
    /// structured result.
    ///
    /// Declarative prompt trees are a `PKPrompt` authoring concept; the shared section model
    /// and token budgeting live in `PKUtilities`. This overload resolves the tree first and
    /// then defers to the section-based budget.
    func result(
        forPrompts prompts: [any Prompt],
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        nodeMetadata: [String: StructuredNodeMetadata] = [:],
        planner: StructuredCompressionPlanner = StructuredCompressionPlanner(),
        executor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) async throws -> TokenBudgetResult {
        try await result(
            forResolvedSections: prompts.flatMap { $0.resolveSections() },
            compressor: compressor,
            structuredDiff: structuredDiff,
            nodeMetadata: nodeMetadata,
            planner: planner,
            executor: executor
        )
    }
}
