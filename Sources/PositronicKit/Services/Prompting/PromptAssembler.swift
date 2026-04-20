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
        extensionSections: [any PromptComposite] = []
    ) async throws -> AssembledPrompt {
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
    /// Use this overload when you need pipeline overrides, token budgeting, or structured
    /// compression configuration.
    public static func assemble(
        _ request: LLMPromptRequest,
        agentInstance: AgentInstance? = nil,
        timeline: Timeline? = nil,
        extensionSections: [any PromptComposite] = [],
        options: PromptAssemblyOptions
    ) async throws -> AssembledPrompt {
        let assemblyContext = PromptAssemblyContext(
            request: request,
            agentInstance: agentInstance,
            timeline: timeline,
            extensionSections: extensionSections
        )

        let sections = try await runPipeline(
            context: assemblyContext,
            overridePipeline: options.overridePipeline
        )
        let resolvedSections = resolveSections(from: sections)
        return try await assemblePrompt(
            from: resolvedSections,
            tokenBudget: options.tokenBudget,
            compressor: options.compressor,
            structuredDiff: options.structuredDiff,
            structuredExecutor: options.structuredExecutor
        )
    }

    /// Builds a prompt and prepares it for LLM submission.
    /// - Parameter request: The prompt request data.
    /// - Returns: A result containing structured messages and the raw prompt string.
    /// - Throws: An error if assembly fails.
    public static func prepare(_ request: LLMPromptRequest) async throws -> LLMPromptResult {
        let prompt = try await assemble(request)
        return LLMPromptResult(messages: await prompt.buildMessages(), rawPrompt: await prompt.buildString())
    }

    /// Builds a prompt for LLM submission using explicit advanced assembly options.
    public static func prepare(
        _ request: LLMPromptRequest,
        options: PromptAssemblyOptions
    ) async throws -> LLMPromptResult {
        let prompt = try await assemble(request, options: options)
        return LLMPromptResult(messages: await prompt.buildMessages(), rawPrompt: await prompt.buildString())
    }

    private static func runPipeline(
        context: PromptAssemblyContext,
        overridePipeline: PromptAssemblyPipeline?
    ) async throws -> [any PromptComposite] {
        let pipeline = overridePipeline ?? PromptAssemblyPipeline(stages: defaultAssemblyStages())

        let stream = pipeline.execute(context)
        for try await _ in stream {}

        let sections = await context.sections
        let duplicateIDs = duplicateResolvedSectionIDs(in: sections.flatMap { $0.resolve(in: PromptResolutionContext()) })
        guard duplicateIDs.isEmpty else {
            throw PromptSectionValidationError.duplicateSectionIDs(duplicateIDs)
        }
        return sections
    }

    private static func duplicateResolvedSectionIDs(in sections: [ResolvedPromptSection]) -> [String] {
        var counts: [String: Int] = [:]
        for section in sections {
            counts[section.id, default: 0] += 1
        }

        return counts
            .filter { $0.value > 1 }
            .map(\.key)
            .sorted()
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
    ) async throws -> AssembledPrompt {
        guard let tokenBudget else {
            return try AssembledPrompt(resolvedSections: resolvedSections)
        }

        let metadata = await buildStructuredMetadata(for: resolvedSections)

        let compressionResult = await tokenBudget.applyWithReport(
            to: resolvedSections,
            compressor: compressor,
            structuredDiff: structuredDiff,
            nodeMetadata: metadata,
            executor: structuredExecutor
        )

        return try AssembledPrompt(
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
            // Include both resolved content and inherited traits in the cache key so
            // structured compression invalidates whenever a materially relevant field changes.
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
