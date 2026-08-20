import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities

/// Pure, stateless runtime adapter over `PKPrompt` assembly.
///
/// `PromptAssembler` is where the runtime turns thread/chat/tool state into a concrete prompt
/// artifact for provider submission. It is intentionally not the public prompt authoring surface;
/// `PKPrompt` owns prompt composition and journaling APIs, while this type owns runtime-side stage
/// ordering, token-budget policy, and compression metadata wiring.
enum PromptAssembler {
    // MARK: - Assemble

    /// Assembles a prompt using the default pipeline and default assembly behavior.
    ///
    /// This is the preferred entry point for most callers.
    /// - Parameters:
    ///   - request: The prompt request data.
    ///   - agent: Optional agent for identity context.
    ///   - thread: Optional thread metadata.
    ///   - extensionSections: Optional additional sections from external extensions.
    /// - Returns: A fully assembled prompt artifact.
    /// - Throws: An error if pipeline execution fails.
    static func assemble(
        _ request: LLMPromptRequest,
        agent: Agent? = nil,
        agentContext: AgentContextSnapshot? = nil,
        thread: Thread? = nil,
        extensionSections: [any Prompt] = []
    ) async throws -> RenderedPrompt {
        try await assemble(
            request,
            agent: agent,
            agentContext: agentContext,
            thread: thread,
            extensionSections: extensionSections,
            options: PromptAssemblyOptions()
        )
    }

    /// Assembles a prompt using explicit advanced assembly options.
    ///
    /// Use this overload when you need custom sections or token-budgeted compression.
    ///
    /// When `options.tokenBudget` is present and the resolved prompt is over budget, prompt
    /// assembly first runs the structured compression pass with section metadata and then falls
    /// back to the simpler priority-based token allocator if the prompt is still over budget.
    static func assemble(
        _ request: LLMPromptRequest,
        agent: Agent? = nil,
        agentContext: AgentContextSnapshot? = nil,
        thread: Thread? = nil,
        extensionSections: [any Prompt] = [],
        options: PromptAssemblyOptions
    ) async throws -> RenderedPrompt {
        let sections = try await buildSections(
            request: request,
            agent: agent,
            agentContext: agentContext,
            thread: thread,
            extensionSections: extensionSections,
            customSections: options.customSections,
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
    static func prepare(_ request: LLMPromptRequest) async throws -> LLMPromptResult {
        let rendered = try await assemble(request)
        return LLMPromptResult(messages: rendered.buildMessages(), rawPrompt: rendered.string)
    }

    /// Builds a prompt for LLM submission using explicit advanced assembly options.
    static func prepare(
        _ request: LLMPromptRequest,
        options: PromptAssemblyOptions
    ) async throws -> LLMPromptResult {
        let rendered = try await assemble(request, options: options)
        return LLMPromptResult(messages: rendered.buildMessages(), rawPrompt: rendered.string)
    }

    private static func buildSections(
        request: LLMPromptRequest,
        agent: Agent?,
        agentContext: AgentContextSnapshot?,
        thread: Thread?,
        extensionSections: [any Prompt],
        customSections: (@Sendable () async -> [any Prompt])?,
        logger: Logger?
    ) async throws -> [any Prompt] {
        if let customSections {
            let sections = await customSections()
            let duplicateIDs = sections.flatMap { $0.resolveSections() }.duplicateIDs(idKeyPath: \.id)
            guard duplicateIDs.isEmpty else {
                throw AssembledPrompt.ValidationError.duplicateSectionIDs(duplicateIDs)
            }
            return sections
        }

        var sections: [any Prompt] = []
        try sections.append(withLogging("SystemInstructions", logger: logger) {
            SystemInstructions(request.systemInstructions ?? DefaultInstructions.system())
        })
        if let agentContext {
            try sections.append(withLogging("AgentIdentity", logger: logger) {
                AgentIdentityContext(snapshot: agentContext, threadTitle: thread?.title)
            })
            if !agentContext.instructions.isEmpty {
                try sections.append(withLogging("AgentInstructions", logger: logger) {
                    AgentInstructionsContext(agentContext.instructions)
                })
            }
            if !agentContext.memories.isEmpty {
                try sections.append(withLogging("AgentMemory", logger: logger) {
                    AgentMemoryContext(agentContext.memories)
                })
            }
            if agentContext.primaryThreadSummary != nil {
                try sections.append(withLogging("AgentPrimaryThreadSummary", logger: logger) {
                    AgentPrimaryThreadSummaryContext(agentContext.primaryThreadSummary)
                })
            }
        } else if let agent {
            try sections.append(withLogging("AgentContext", logger: logger) {
                AgentContext(agent, threadTitle: thread?.title)
            })
        }
        try sections.append(withLogging("ContextNotes", logger: logger) { ContextNotes(request.contextNotes) })
        try sections.append(withLogging("Memories", logger: logger) { Memories(request.memories) })
        try sections.append(withLogging("Tools", logger: logger) { Tools(request.tools) })
        try sections.append(withLogging("WorkspacesContext", logger: logger) {
            WorkspacesContext(workspaces: request.workspaces, primaryWorkspace: request.primaryWorkspace, requestOriginName: request.requestOriginName)
        })
        if let thread {
            try sections.append(withLogging("ThreadContext", logger: logger) { ThreadContext(thread) })
        }
        try sections.append(withLogging("ChatHistory", logger: logger) {
            ChatHistory(PromptHistoryOptimizer.optimizeForDefaultBudget(request.chatHistory))
        })
        try sections.append(withLogging("UserQuery", logger: logger) {
            UserQuery(request.userContent, turnInstructions: request.turnInstructions)
        })
        sections.append(contentsOf: extensionSections)

        let duplicateIDs = sections.flatMap { $0.resolveSections() }.duplicateIDs(idKeyPath: \.id)
        guard duplicateIDs.isEmpty else {
            throw AssembledPrompt.ValidationError.duplicateSectionIDs(duplicateIDs)
        }
        return sections
    }

    private static func withLogging<T>(_ id: String, logger: Logger?, _ body: () throws -> T) throws -> T {
        logger?.debug("Starting prompt section: \(id)")
        let start = Date().timeIntervalSinceReferenceDate
        do {
            let result = try body()
            let duration = Date().timeIntervalSinceReferenceDate - start
            logger?.debug("Completed prompt section: \(id) in \(String(format: "%.3f", duration))s")
            return result
        } catch {
            let duration = Date().timeIntervalSinceReferenceDate - start
            logger?.error("Prompt section '\(id)' failed after \(String(format: "%.3f", duration))s: \(error.localizedDescription)")
            throw error
        }
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

        let compressionResult = try await tokenBudget.result(
            forResolvedSections: resolvedSections,
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
            metadata[section.id] = section.nodeMetadata(renderedContent: rendered)
        }
        return metadata
    }
}
