import Foundation
import PKPrompt
import PKShared

/// Pure, stateless prompt assembly service.
/// Provides high-level methods to build prompts and optimize conversation history.
public enum PromptBuilder {
    // MARK: - Constants

    /// The maximum number of tokens allowed for chat history in a prompt.
    public static let maxHistoryTokens = 120_000
    /// A buffer reserved for other prompt sections to ensure history doesn't crowd them out.
    public static let historyTokenBuffer = 4000

    // MARK: - Default Stages

    /// Returns the standard sequence of stages used to assemble a prompt.
    /// - Returns: An array of pipeline stages in their default execution order.
    public static func defaultAssemblyStages() -> [any PipelineStage<PromptAssemblyContext, PromptAssemblyEvent>] {
        [
            SystemInstructionsStage(),
            AgentContextStage(),
            ContextNotesStage(),
            MemoriesStage(),
            ToolsStage(),
            WorkspacesContextStage(),
            TimelineContextStage(),
            ChatHistoryStage(),
            UserQueryStage(),
            ExtensionSectionsStage(),
        ]
    }

    // MARK: - Build Context

    /// Assembles a `Prompt` by executing the assembly pipeline.
    /// - Parameters:
    ///   - request: The prompt request data.
    ///   - agentInstance: Optional agent instance for identity context.
    ///   - timeline: Optional timeline metadata.
    ///   - extensionSections: Optional additional sections from external extensions.
    ///   - overridePipeline: An optional custom pipeline to use instead of the default.
    /// - Returns: A fully assembled `Prompt` object.
    /// - Throws: An error if pipeline execution fails.
    public static func buildContext(
        _ request: LLMPromptRequest,
        agentInstance: AgentInstance? = nil,
        timeline: Timeline? = nil,
        extensionSections: [any PromptComposite] = [],
        overridePipeline: PromptAssemblyPipeline? = nil,
        tokenBudget: TokenBudget? = nil,
        compressor: SectionCompressor? = nil,
        structuredDiff: StructuredDiffHint? = nil,
        structuredExecutor: StructuredCompressionExecutor = StructuredCompressionExecutor()
    ) async throws -> Prompt {
        let assemblyContext = PromptAssemblyContext(
            request: request,
            agentInstance: agentInstance,
            timeline: timeline,
            extensionSections: extensionSections
        )

        let pipeline = overridePipeline ?? PromptAssemblyPipeline(stages: defaultAssemblyStages())

        // Execute the pipeline and drain the events.
        let stream = pipeline.execute(assemblyContext)
        for try await _ in stream {}

        let sections = await assemblyContext.sections
        try validateUniqueSectionIDs(sections)

        let resolvedSections = sections.flatMap { $0.resolve(in: PromptResolutionContext()) }

        guard let tokenBudget else {
            return Prompt(sections: sections)
        }

        var metadata: [String: StructuredNodeMetadata] = [:]
        for section in resolvedSections {
            let rendered = await section.render() ?? ""
            metadata[section.id] = StructuredNodeMetadata(
                path: section.path,
                nodeHash: StableHash.hash(components: [
                    section.id,
                    String(section.estimatedTokens),
                    String(section.priority),
                    String(describing: section.cachePolicy),
                    rendered,
                ])
            )
        }

        let compressionResult = await tokenBudget.applyWithReport(
            to: resolvedSections,
            compressor: compressor,
            structuredDiff: structuredDiff,
            nodeMetadata: metadata,
            executor: structuredExecutor
        )

        return Prompt(
            sections: sections,
            resolvedSections: compressionResult.sections,
            compressionReport: compressionResult.report
        )
    }

    /// Builds a prompt and prepares it for LLM submission.
    /// - Parameter request: The prompt request data.
    /// - Returns: A result containing structured messages and the raw prompt string.
    /// - Throws: An error if assembly fails.
    public static func buildPrompt(_ request: LLMPromptRequest) async throws -> LLMPromptResult {
        let prompt = try await buildContext(request)
        let renderedContent = await prompt.renderAll()
        let messages = await prompt.toMessages(preRendered: renderedContent)
        let raw = await prompt.render(preRendered: renderedContent)
        return LLMPromptResult(messages: messages, rawPrompt: raw)
    }

    // MARK: - History Optimization

    /// Truncates conversation history to fit within a specified token budget.
    /// Keeps the most recent messages and inserts a truncation notice if needed.
    /// - Parameters:
    ///   - messages: The full array of conversation messages.
    ///   - availableTokens: The maximum tokens allowed for history.
    /// - Returns: A truncated array of messages that fits the budget.
    public static func optimizeHistory(
        _ messages: [Message],
        availableTokens: Int
    ) -> [Message] {
        guard availableTokens > 0 else { return [] }

        var result: [Message] = []
        var usedTokens = 0

        for message in messages.reversed() {
            let tokens = TokenEstimator.estimate(text: message.content)
            if usedTokens + tokens <= availableTokens {
                result.insert(message, at: 0)
                usedTokens += tokens
            } else {
                // Only insert summary if we actually skipped messages and have some space
                if result.count < messages.count, availableTokens >= 100 {
                    let skippedCount = messages.count - result.count
                    let summary = Message(
                        content: "[System: History truncated. \(skippedCount) earlier messages hidden. " +
                            "Use `view_chat_history` tool to retrieve them.]",
                        role: .system,
                        isSummary: true
                    )
                    result.insert(summary, at: 0)
                }
                break
            }
        }
        return result
    }
}
