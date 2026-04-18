import Foundation
import PKPrompt
import PKShared

/// Pure, stateless prompt assembly service.
/// Provides high-level methods to build prompts and optimize conversation history.
public enum PromptAssembler {
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
    ) async throws -> AssembledPrompt {
        let assemblyContext = PromptAssemblyContext(
            request: request,
            agentInstance: agentInstance,
            timeline: timeline,
            extensionSections: extensionSections
        )

        let sections = try await runPipeline(
            context: assemblyContext,
            overridePipeline: overridePipeline
        )
        let resolvedSections = resolveSections(from: sections)
        return await assemblePrompt(
            from: resolvedSections,
            tokenBudget: tokenBudget,
            compressor: compressor,
            structuredDiff: structuredDiff,
            structuredExecutor: structuredExecutor
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

    private static func runPipeline(
        context: PromptAssemblyContext,
        overridePipeline: PromptAssemblyPipeline?
    ) async throws -> [any PromptComposite] {
        let pipeline = overridePipeline ?? PromptAssemblyPipeline(stages: defaultAssemblyStages())

        let stream = pipeline.execute(context)
        for try await _ in stream {}

        let sections = await context.sections
        try validateUniqueSectionIDs(sections)
        return sections
    }

    private static func resolveSections(from sections: [any PromptComposite]) -> [ResolvedPromptSection] {
        sections.flatMap { $0.resolve(in: PromptResolutionContext()) }
    }

    private static func assemblePrompt(
        from resolvedSections: [ResolvedPromptSection],
        tokenBudget: TokenBudget?,
        compressor: SectionCompressor?,
        structuredDiff: StructuredDiffHint?,
        structuredExecutor: StructuredCompressionExecutor
    ) async -> AssembledPrompt {
        guard let tokenBudget else {
            return AssembledPrompt(resolvedSections: resolvedSections)
        }

        let metadata = await buildStructuredMetadata(for: resolvedSections)

        let compressionResult = await tokenBudget.applyWithReport(
            to: resolvedSections,
            compressor: compressor,
            structuredDiff: structuredDiff,
            nodeMetadata: metadata,
            executor: structuredExecutor
        )

        return AssembledPrompt(
            resolvedSections: compressionResult.sections,
            compressionReport: compressionResult.report
        )
    }

    private static func buildStructuredMetadata(
        for resolvedSections: [ResolvedPromptSection]
    ) async -> [String: StructuredNodeMetadata] {
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
        return metadata
    }
}
