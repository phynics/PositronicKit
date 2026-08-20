import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// Advanced options for prompt assembly.
///
/// Runtime-owned assembly options used by the turn pipeline and focused tests. Consumer prompt
/// ownership belongs on the direct Turn request surface.
///
/// When `tokenBudget` is set, `PromptAssembler` first attempts structured compression using
/// resolved section metadata and `structuredExecutor`. If the structured result is still over
/// budget, it falls back to the simpler priority-based `TokenBudget` path.
struct PromptAssemblyOptions: Sendable {
    var customSections: (@Sendable () async -> [any Prompt])? = nil
    var tokenBudget: TokenBudget?
    var logger: Logger?
    /// Optional summarization service used by `.summarize` compression actions once a prompt is
    /// over budget and token reduction is required.
    ///
    /// If omitted, summarize actions degrade to drop behavior in the compression pipeline.
    var compressor: SectionCompressor?
    /// Optional diff hint that helps the structured planner prioritize changed nodes.
    var structuredDiff: StructuredDiffHint?
    /// Executor used for the structured compression pass that runs before fallback budgeting
    /// whenever prompt assembly applies a token budget.
    var structuredExecutor: StructuredCompressionExecutor

    init(
        customSections: (@Sendable () async -> [any Prompt])? = nil,
        tokenBudget: TokenBudget? = nil,
        logger: Logger? = nil,
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        structuredExecutor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) {
        self.customSections = customSections
        self.tokenBudget = tokenBudget
        self.logger = logger
        self.compressor = compressor
        self.structuredDiff = structuredDiff
        self.structuredExecutor = structuredExecutor
    }
}
