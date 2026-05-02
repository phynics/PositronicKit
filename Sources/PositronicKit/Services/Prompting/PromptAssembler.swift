import Foundation
import Logging
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
            ExtensionSectionsStage()
        ]
    }

    // MARK: - Assemble

    /// Assembles a prompt using the default pipeline and default assembly behavior.
    ///
    /// This is the preferred entry point for most callers.
    /// - Parameters:
    ///   - request: The prompt request data.
    ///   - agentInstance: Optional agent instance for identity context.
    ///   - timeline: Optional timeline metadata.
    ///   - extensionSections: Optional additional sections from external extensions.
    /// - Returns: A fully assembled prompt artifact.
    /// - Throws: An error if pipeline execution fails.
    public static func assemble(
        _ request: LLMPromptRequest,
        agentInstance: AgentInstance? = nil,
        timeline: Timeline? = nil,
        extensionSections: [any Prompt] = []
    ) async throws -> RenderedPrompt {
        try await assemble(
            request,
            agentInstance: agentInstance,
            timeline: timeline,
            extensionSections: extensionSections,
            options: PromptAssemblyOptions()
        )
    }

    /// Assembles a prompt using explicit advanced assembly options.
    ///
    /// Use this overload when you need pipeline overrides or token-budgeted compression.
    ///
    /// When `options.tokenBudget` is present and the resolved prompt is over budget, prompt
    /// assembly first runs the structured compression pass with section metadata and then falls
    /// back to the simpler priority-based token allocator if the prompt is still over budget.
    public static func assemble(
        _ request: LLMPromptRequest,
        agentInstance: AgentInstance? = nil,
        timeline: Timeline? = nil,
        extensionSections: [any Prompt] = [],
        options: PromptAssemblyOptions
    ) async throws -> RenderedPrompt {
        let assemblyContext = PromptAssemblyContext(
            request: request,
            agentInstance: agentInstance,
            timeline: timeline,
            extensionSections: extensionSections
        )

        let sections = try await runPipeline(
            context: assemblyContext,
            overridePipeline: options.overridePipeline,
            logger: options.logger
        )
        let resolvedSections = resolveSections(from: sections)
        options.logger?.debug(
            "Resolved \(resolvedSections.count) prompt section(s) from \(sections.count) prompt fragment(s)."
        )
        let prompt = try await assemblePrompt(
            from: resolvedSections,
            tokenBudget: options.tokenBudget,
            compressor: options.compressor,
            structuredDiff: options.structuredDiff,
            structuredExecutor: options.structuredExecutor,
            logger: options.logger
        )
        return await prompt.render()
    }

    /// Builds a prompt and prepares it for LLM submission.
    /// - Parameter request: The prompt request data.
    /// - Returns: A result containing structured messages and the raw prompt string.
    /// - Throws: An error if assembly fails.
    public static func prepare(_ request: LLMPromptRequest) async throws -> LLMPromptResult {
        let rendered = try await assemble(request)
        return LLMPromptResult(messages: rendered.buildMessages(), rawPrompt: rendered.string)
    }

    /// Builds a prompt for LLM submission using explicit advanced assembly options.
    public static func prepare(
        _ request: LLMPromptRequest,
        options: PromptAssemblyOptions
    ) async throws -> LLMPromptResult {
        let rendered = try await assemble(request, options: options)
        return LLMPromptResult(messages: rendered.buildMessages(), rawPrompt: rendered.string)
    }

    private static func runPipeline(
        context: PromptAssemblyContext,
        overridePipeline: Pipeline<PromptAssemblyContext, PromptAssemblyEvent>?,
        logger: Logger?
    ) async throws -> [any Prompt] {
        let basePipeline = overridePipeline ?? Pipeline(stages: defaultAssemblyStages())
        let pipeline = if let logger {
            basePipeline.withLogger(logger)
        } else {
            basePipeline
        }

        let stream = pipeline.execute(context)
        for try await _ in stream {}

        let sections = await context.sections
        let duplicateIDs = duplicateResolvedSectionIDs(in: sections.flatMap { $0.resolveSections() })
        guard duplicateIDs.isEmpty else {
            throw AssembledPrompt.ValidationError.duplicateSectionIDs(duplicateIDs)
        }
        return sections
    }

    private static func duplicateResolvedSectionIDs(in sections: [PromptSection]) -> [String] {
        var counts: [String: Int] = [:]
        for section in sections {
            counts[section.id, default: 0] += 1
        }

        return counts
            .filter { $0.value > 1 }
            .map(\.key)
            .sorted()
    }

    private static func resolveSections(from sections: [any Prompt]) -> [PromptSection] {
        sections.flatMap { $0.resolveSections() }
    }

    private static func assemblePrompt(
        from resolvedSections: [PromptSection],
        tokenBudget: TokenBudget?,
        compressor: SectionCompressor?,
        structuredDiff: StructuredDiffHint?,
        structuredExecutor: StructuredCompressionExecutor,
        logger: Logger?
    ) async throws -> AssembledPrompt {
        guard let tokenBudget else {
            logger?.debug("Assembling prompt without token budget.")
            return try AssembledPrompt(sections: resolvedSections)
        }

        logger?.debug(
            "Applying token budget with maxTokens=\(tokenBudget.maxTokens) reserveForResponse=\(tokenBudget.reserveForResponse)."
        )

        // Prompt assembly always provides node metadata for budgeted prompts, so the structured
        // compression pass runs first and the simple allocator acts as a fallback.
        let metadata = await buildStructuredMetadata(for: resolvedSections)

        let compressionResult = await tokenBudget.applyWithReport(
            to: resolvedSections,
            compressor: compressor,
            structuredDiff: structuredDiff,
            nodeMetadata: metadata,
            executor: structuredExecutor
        )

        logger?.debug(
            "Token budgeting produced \(compressionResult.sections.count) prompt section(s)."
        )

        return try AssembledPrompt(
            sections: compressionResult.sections,
            compressionReport: compressionResult.report
        )
    }

    private static func buildStructuredMetadata(
        for resolvedSections: [PromptSection]
    ) async -> [String: StructuredNodeMetadata] {
        var metadata: [String: StructuredNodeMetadata] = [:]
        for section in resolvedSections {
            let rendered = await section.renderedContent()?.text ?? ""
            // Include both resolved content and inherited traits in the cache key so
            // structured compression invalidates whenever a materially relevant field changes.
            metadata[section.id] = StructuredNodeMetadata(
                path: section.path,
                nodeHash: StableHash.hash(components: [
                    section.id,
                    String(section.estimatedTokens),
                    String(section.priority),
                    String(describing: section.cachePolicy),
                    rendered
                ])
            )
        }
        return metadata
    }
}
