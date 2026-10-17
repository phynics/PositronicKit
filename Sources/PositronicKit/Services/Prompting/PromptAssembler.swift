import Foundation
import Logging
import PKContracts
import PKUtilities

/// Pure, stateless runtime prompt assembly.
///
/// `PromptAssembler` is where the runtime turns timeline/chat/tool state into a concrete prompt
/// artifact for provider submission. It builds runtime-owned `PromptSection`s directly; the
/// optional `PKPrompt` authoring product is not part of this path.
enum PromptAssembler {
    // MARK: - Assemble

    /// Assembles a prompt using the default pipeline and default assembly behavior.
    ///
    /// This is the preferred entry point for most callers.
    /// - Parameters:
    ///   - request: The prompt request data.
    ///   - agent: Optional agent for identity context.
    ///   - timeline: Optional timeline metadata.
    /// - Returns: A fully assembled prompt artifact.
    /// - Throws: An error if pipeline execution fails.
    static func assemble(
        _ request: LLMPromptRequest,
        agent: Agent? = nil,
        agentContext: AgentContextSnapshot? = nil,
        timeline: TimelineRecord? = nil
    ) async throws -> RenderedPrompt {
        try await assemble(
            request,
            agent: agent,
            agentContext: agentContext,
            timeline: timeline,
            options: PromptAssemblyOptions()
        )
    }

    /// Assembles a prompt using explicit advanced assembly options.
    ///
    /// Runtime Turns use this overload to pass an optional history projection replacement.
    /// Prompt assembly never compresses or summarizes content; the caller owns overflow handling
    /// through projection, stepwise history trimming, or a structured preparation failure.
    static func assemble(
        _ request: LLMPromptRequest,
        agent: Agent? = nil,
        agentContext: AgentContextSnapshot? = nil,
        timeline: TimelineRecord? = nil,
        options: PromptAssemblyOptions
    ) async throws -> RenderedPrompt {
        let build = try await buildSections(
            request: request,
            agent: agent,
            agentContext: agentContext,
            timeline: timeline,
            customSections: options.customSections,
            historyProjectionReplacement: options.historyProjectionReplacement,
            logger: options.logger
        )
        options.logger?.debug(
            "Resolved \(build.sections.count) prompt section(s) from \(build.fragmentCount) prompt fragment(s)."
        )
        let assembled = try AssembledPrompt(sections: build.sections)
        return await assembled.render()
    }

    /// Builds a prompt and prepares it for LLM submission.
    /// - Parameter request: The prompt request data.
    /// - Returns: Structured messages and the raw prompt string.
    /// - Throws: An error if assembly fails.
    static func prepare(_ request: LLMPromptRequest) async throws -> (messages: [LLMMessage], rawPrompt: String) {
        let rendered = try await assemble(request)
        let layout = PromptLayoutBuilder.build(from: rendered)
        return (messages: layout.renderMessages(), rawPrompt: rendered.string)
    }

    /// Builds a prompt for LLM submission using explicit advanced assembly options.
    static func prepare(
        _ request: LLMPromptRequest,
        options: PromptAssemblyOptions
    ) async throws -> (messages: [LLMMessage], rawPrompt: String) {
        let rendered = try await assemble(request, options: options)
        let layout = PromptLayoutBuilder.build(from: rendered)
        return (messages: layout.renderMessages(), rawPrompt: rendered.string)
    }

    private struct SectionBuild {
        let fragmentCount: Int
        let sections: [PromptSection]
    }

    private static func buildSections(
        request: LLMPromptRequest,
        agent: Agent?,
        agentContext: AgentContextSnapshot?,
        timeline: TimelineRecord?,
        customSections: (@Sendable () async -> [PromptSection])?,
        historyProjectionReplacement: String?,
        logger: Logger?
    ) async throws -> SectionBuild {
        if let customSections {
            let sections = await customSections()
            let duplicateIDs = sections.duplicateIDs(idKeyPath: \.id)
            guard duplicateIDs.isEmpty else {
                throw PromptAssemblyError.duplicateSectionIDs(duplicateIDs)
            }
            return SectionBuild(fragmentCount: sections.count, sections: sections)
        }

        var fragments: [RuntimePromptProducer] = []
        try fragments.append(withLogging("SystemInstructions", logger: logger) {
            SystemInstructions(request.systemInstructions ?? DefaultInstructions.system())
        })
        if let agentContext {
            try fragments.append(withLogging("AgentIdentity", logger: logger) {
                AgentIdentityContext(snapshot: agentContext)
            })
            if !agentContext.instructions.isEmpty {
                try fragments.append(withLogging("AgentInstructions", logger: logger) {
                    AgentInstructionsContext(agentContext.instructions)
                })
            }
            if !agentContext.memories.isEmpty {
                try fragments.append(withLogging("AgentMemory", logger: logger) {
                    AgentMemoryContext(agentContext.memories)
                })
            }
            if !agentContext.resources.isEmpty {
                try fragments.append(withLogging("AgentResourceCatalog", logger: logger) {
                    AgentResourceCatalogContext(agentContext.resources)
                })
            }
            if agentContext.primaryTimelineSummary != nil {
                try fragments.append(withLogging("AgentPrimaryTimelineSummary", logger: logger) {
                    AgentPrimaryTimelineSummaryContext(agentContext.primaryTimelineSummary)
                })
            }
        } else if let agent {
            try fragments.append(withLogging("AgentContext", logger: logger) {
                AgentContext(agent)
            })
        }
        if !request.contextContributions.isEmpty {
            try fragments.append(withLogging("TurnContextContributions", logger: logger) {
                TurnContextContributions(request.contextContributions)
            })
        }
        try fragments.append(withLogging("Tools", logger: logger) { Tools(request.tools) })
        try fragments.append(withLogging("WorkspacesContext", logger: logger) {
            WorkspacesContext(workspaces: request.workspaces, primaryWorkspace: request.primaryWorkspace, requestOriginName: request.requestOriginName)
        })
        if let timeline {
            try fragments.append(withLogging("TimelineContext", logger: logger) { TimelineContext(timeline) })
        }
        if let historyProjectionReplacement {
            try fragments.append(withLogging("HistoryProjection", logger: logger) {
                HistoryProjectionSection(replacement: historyProjectionReplacement)
            })
        }
        try fragments.append(withLogging("ChatHistory", logger: logger) {
            ChatHistory(request.chatHistory)
        })
        try fragments.append(withLogging("UserQuery", logger: logger) {
            UserQuery(request.userContent, turnInstructions: request.turnInstructions)
        })

        let sections = fragments.flatMap { $0.makeSections() }
        let duplicateIDs = sections.duplicateIDs(idKeyPath: \.id)
        guard duplicateIDs.isEmpty else {
            throw PromptAssemblyError.duplicateSectionIDs(duplicateIDs)
        }
        return SectionBuild(fragmentCount: fragments.count, sections: sections)
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
}
