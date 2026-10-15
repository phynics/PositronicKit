import Foundation
import PKContracts
import PKUtilities

// MARK: - Runtime Prompt Producers

/// A runtime-owned producer of concrete prompt sections.
///
/// Runtime section types build `PromptSection`s directly instead of conforming to the
/// optional `PKPrompt` authoring DSL. The produced sections carry the same identity,
/// ordering, cache policy, and rendering behavior the runtime used before the runtime was
/// decoupled from `PKPrompt`.
protocol RuntimePromptProducer: Sendable {
    func makeSections() -> [PromptSection]
}

extension RuntimePromptProducer {
    /// Renders the produced sections into their canonical plain-text representation.
    ///
    /// Returns `nil` when the produced prompt has no renderable content.
    func renderToString() async throws -> String? {
        let assembled = try AssembledPrompt(sections: makeSections())
        let rendered = await assembled.render().string
        return rendered.isEmpty ? nil : rendered
    }
}

/// Builds concrete `PromptSection`s for the runtime without the authoring DSL.
enum RuntimePromptSectionFactory {
    static func text(
        id: String,
        role: PromptSectionRole,
        priority: Int,
        estimatedTokens: Int,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy,
        path: [String],
        parentID: String? = nil,
        render: @escaping @Sendable () async -> String?
    ) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: compression,
            type: .text,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            render: { limit in
                guard let content = await render(), !content.isEmpty else { return nil }
                guard let constrained = constrain(content, tokens: limit, strategy: compression) else {
                    return nil
                }
                return .text(constrained)
            }
        )
    }

    static func messages(
        id: String,
        role: PromptSectionRole,
        priority: Int,
        estimatedTokens: Int,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy,
        path: [String],
        parentID: String? = nil,
        messages: [Message]
    ) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: compression,
            type: .list,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            render: { _ in messages.isEmpty ? nil : .messages(messages) }
        )
    }

    static func multimodal(
        id: String,
        role: PromptSectionRole,
        priority: Int,
        estimatedTokens: Int,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy,
        path: [String],
        parentID: String? = nil,
        content: MessageContent
    ) -> PromptSection {
        PromptSection(
            id: id,
            role: role,
            priority: priority,
            estimatedTokens: estimatedTokens,
            compression: compression,
            type: .text,
            cachePolicy: cachePolicy,
            path: path,
            parentID: parentID,
            render: { _ in content.parts.isEmpty ? nil : .multimodal(content) }
        )
    }

    /// Builds a user-query section. Plain text stays plain text so downstream projections keep
    /// the single-text fast path; ordered multimodal parts render as multimodal content.
    static func userQuery(
        id: String,
        priority: Int,
        estimatedTokens: Int,
        cachePolicy: CachePolicy,
        path: [String],
        content: MessageContent
    ) -> PromptSection {
        if content.requiresContentPartsEncoding {
            return multimodal(
                id: id,
                role: .userQuery,
                priority: priority,
                estimatedTokens: estimatedTokens,
                cachePolicy: cachePolicy,
                path: path,
                content: content
            )
        }
        return text(
            id: id,
            role: .userQuery,
            priority: priority,
            estimatedTokens: estimatedTokens,
            cachePolicy: cachePolicy,
            path: path,
            render: { content.text }
        )
    }

    private static func constrain(
        _ content: String,
        tokens: Int?,
        strategy: CompressionStrategy
    ) -> String? {
        guard let tokens else { return content }
        assert(tokens > 0)
        let estimate = TokenEstimator.estimate(text: content)
        guard estimate > tokens else { return content }
        switch strategy {
        case .keep:
            return content
        case let .truncate(retention):
            let charLimit = tokens * 2
            switch retention {
            case .head:
                return String(content.prefix(charLimit)) + "\n... [Truncated]"
            case .tail:
                return "... [Truncated]\n" + String(content.suffix(charLimit))
            }
        case .summarize:
            return content
        case .drop:
            return nil
        }
    }
}

// MARK: - Sections

/// Runtime-owned stable system instructions section.
struct SystemInstructions: RuntimePromptProducer {
    let instructions: String

    init(_ instructions: String) {
        self.instructions = instructions
    }

    func makeSections() -> [PromptSection] {
        guard !instructions.isEmpty else { return [] }
        let text = """
        # System Instructions

        \(instructions)
        """
        return [RuntimePromptSectionFactory.text(
            id: "system",
            role: .system,
            priority: PromptPriority.critical.rawValue,
            estimatedTokens: TokenEstimator.estimate(text: instructions),
            cachePolicy: .stable,
            path: ["prompt", "SystemInstructions", "SystemPrompt", "stable", "system"],
            render: { text }
        )]
    }
}

/// Runtime-owned tool catalog section.
struct Tools: RuntimePromptProducer {
    let tools: [AnyTool]

    init(_ tools: [AnyTool]) {
        self.tools = tools
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.text(
            id: "tools",
            role: .context,
            priority: 80,
            estimatedTokens: tools.count * 50,
            cachePolicy: .semiStable,
            path: ["prompt", "Tools", "TextPrompt", "semiStable", "tools"],
            render: { [tools] in
                guard !tools.isEmpty else { return nil }
                return await tools.formattedForPrompt()
            }
        )]
    }
}

/// Runtime-owned chat-history section.
struct ChatHistory: RuntimePromptProducer {
    let messages: [Message]

    init(_ messages: [Message]) {
        self.messages = messages
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.messages(
            id: "chat_history",
            role: .chatHistory,
            priority: 70,
            estimatedTokens: estimatedTokens,
            compression: .truncate(keeping: .tail),
            cachePolicy: .volatile,
            path: ["prompt", "ChatHistory", "HistoryPrompt", "volatile", "chat_history"],
            messages: messages
        )]
    }

    func constrained(to tokens: Int) -> ChatHistory {
        guard estimatedTokens > tokens else { return self }

        var accumulated = 0
        var keepCount = 0

        for message in messages.reversed() {
            let count = TokenEstimator.estimate(text: message.content) + 10
            if accumulated + count > tokens {
                break
            }
            accumulated += count
            keepCount += 1
        }

        return ChatHistory(Array(messages.suffix(keepCount)))
    }

    /// The estimated number of tokens across all message content.
    ///
    /// - Complexity: O(n), where n is the total number of characters in `messages`.
    var estimatedTokens: Int {
        TokenEstimator.estimate(parts: messages.map(\.content))
    }
}

/// A bounded replacement for a covered historical prefix.
///
/// Rendered as one semi-stable history section with a stable identity so prompt-history
/// diffing treats a projection change as a deliberate prefix reset rather than an
/// inconsistency. The retained tail stays in the ordinary `chat_history` section.
struct HistoryProjectionSection: RuntimePromptProducer {
    let replacement: String

    init(replacement: String) {
        self.replacement = replacement
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.messages(
            id: "runtime.history-projection",
            role: .chatHistory,
            priority: 71,
            estimatedTokens: TokenEstimator.estimate(text: replacement),
            cachePolicy: .semiStable,
            path: ["prompt", "HistoryProjectionSection", "HistoryPrompt", "semiStable", "runtime.history-projection"],
            messages: [Message(content: replacement, role: .summary, isSummary: true)]
        )]
    }
}

/// Bounded host-provided values captured for one Turn.
struct TurnContextContributions: RuntimePromptProducer {
    let contributions: [TurnContextContribution]

    init(_ contributions: [TurnContextContribution]) {
        self.contributions = contributions
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.text(
            id: "turn.context-contributions",
            role: .context,
            priority: 89,
            estimatedTokens: TokenEstimator.estimate(parts: contributions.map { $0.value.textValue }),
            compression: .truncate(keeping: .head),
            cachePolicy: .volatile,
            path: ["prompt", "TurnContextContributions", "TextPrompt", "volatile", "turn.context-contributions"],
            render: { [contributions] in
                guard !contributions.isEmpty else { return nil }
                let values = contributions.map { contribution in
                    "[\(contribution.namespace).\(contribution.key)]\n\(contribution.value.textValue)"
                }.joined(separator: "\n\n")
                return "## Turn Context\n\n\(values)"
            }
        )]
    }
}

/// Runtime-owned current user query section.
struct UserQuery: RuntimePromptProducer {
    let content: MessageContent
    var query: String { content.text }
    /// Optional per-turn instructions rendered after the query inside the same
    /// `.userQuery` section (single-section invariant preserved; volatile cache policy).
    let turnInstructions: String?

    init(_ query: String, turnInstructions: String? = nil) {
        content = MessageContent(query)
        self.turnInstructions = turnInstructions
    }

    init(_ content: MessageContent, turnInstructions: String? = nil) {
        self.content = content
        self.turnInstructions = turnInstructions
    }

    func makeSections() -> [PromptSection] {
        let resolved: MessageContent = {
            guard let turnInstructions, !turnInstructions.isEmpty else { return content }
            return MessageContent(parts: content.parts + [.text("\n" + turnInstructions)])
        }()
        return [RuntimePromptSectionFactory.userQuery(
            id: "user_query",
            priority: 10,
            estimatedTokens: resolved.estimatedTokens,
            cachePolicy: .volatile,
            path: ["prompt", "UserQuery", "UserPrompt", "volatile", "user_query"],
            content: resolved
        )]
    }
}

/// Runtime-owned workspace catalog section.
struct WorkspacesContext: RuntimePromptProducer {
    let workspaces: [WorkspaceReference]
    let primaryWorkspace: WorkspaceReference?
    let requestOriginName: String?

    init(
        workspaces: [WorkspaceReference],
        primaryWorkspace: WorkspaceReference?,
        requestOriginName: String?
    ) {
        self.workspaces = workspaces
        self.primaryWorkspace = primaryWorkspace
        self.requestOriginName = requestOriginName
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.text(
            id: "workspaces",
            role: .context,
            priority: 75,
            estimatedTokens: estimatedTokens,
            cachePolicy: .semiStable,
            path: ["prompt", "WorkspacesContext", "TextPrompt", "semiStable", "workspaces"],
            render: { [workspaces, primaryWorkspace, requestOriginName] in
                Self.renderContent(
                    workspaces: workspaces,
                    primaryWorkspace: primaryWorkspace,
                    requestOriginName: requestOriginName
                )
            }
        )]
    }

    private static func renderContent(
        workspaces: [WorkspaceReference],
        primaryWorkspace: WorkspaceReference?,
        requestOriginName: String?
    ) -> String? {
        var output = ""

        if let requestOriginName {
            output += "User Query Origin: **\(requestOriginName)**\n\n"
        }

        let allWorkspaces = (primaryWorkspace.map { [$0] } ?? []) + workspaces.filter { $0.id != primaryWorkspace?.id }
        guard !allWorkspaces.isEmpty else { return output.isEmpty ? nil : output }

        output += "## Available Workspaces\n\n"

        for workspace in allWorkspaces {
            output.append("- Workspace ID: `")
            output.append(workspace.id.uuidString)
            output.append("`\n  Location: `")
            output.append(workspace.uri.description)
            output.append("`\n")

            if !workspace.tools.isEmpty {
                output.append("  Available Tools:\n")
                for tool in workspace.tools {
                    output.append("    - `")
                    output.append(tool.toolID)
                    output.append("`\n")
                    if let toolInjection = tool.contextInjection, !toolInjection.isEmpty {
                        output.append("      Instructions: \(toolInjection)\n")
                    }
                }
            } else {
                output.append("  Available Tools: None specific to this workspace\n")
            }

            if let wsInjection = workspace.contextInjection, !wsInjection.isEmpty {
                output.append("  Workspace Instructions: \(wsInjection)\n")
            }

            output += "\n"
        }

        output += "## Workspace Routing Rules\n"
        output += "1. Paths passed to tools MUST be relative to the targeted workspace root.\n"
        output += "2. Treat workspace-tagged tools as already bound to their labeled workspace; do not add workspace ids to tool arguments.\n"

        return output
    }

    private var estimatedTokens: Int {
        TokenEstimator.estimate(text: "Workspaces section placeholder") + workspaces.count * 50
    }
}

/// Runtime-owned Agent identity section.
struct AgentContext: RuntimePromptProducer {
    let snapshot: AgentContextSnapshot
    let timelineTitle: String?

    init(_ agent: Agent, timelineTitle: String? = nil) {
        snapshot = AgentContextSnapshot(agent: agent)
        self.timelineTitle = timelineTitle
    }

    init(_ snapshot: AgentContextSnapshot, timelineTitle: String? = nil) {
        self.snapshot = snapshot
        self.timelineTitle = timelineTitle
    }

    func makeSections() -> [PromptSection] {
        AgentIdentityContext(snapshot: snapshot, timelineTitle: timelineTitle).makeSections()
    }
}

/// Stable Agent identity section owned by the runtime.
struct AgentIdentityContext: RuntimePromptProducer {
    let snapshot: AgentContextSnapshot
    let timelineTitle: String?

    init(snapshot: AgentContextSnapshot, timelineTitle: String? = nil) {
        self.snapshot = snapshot
        self.timelineTitle = timelineTitle
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.text(
            id: "agent.identity",
            role: .system,
            priority: 95,
            estimatedTokens: TokenEstimator.estimate(text: text),
            cachePolicy: .stable,
            path: ["prompt", "AgentIdentityContext", "SystemPrompt", "stable", "agent.identity"],
            render: { [text] in text }
        )]
    }

    private var text: String {
        var lines = ["## Your Identity", "You are **\(snapshot.identity.name)**."]
        if !snapshot.identity.description.isEmpty {
            lines.append("Description: \(snapshot.identity.description)")
        }
        if let timelineTitle {
            lines.append("Currently operating on timeline: \"\(timelineTitle)\"")
        }
        lines.append("Your private workspace supplies persistent continuity. Markdown resources are cataloged from `Notes/` and read on demand with workspace file tools.")
        return lines.joined(separator: "\n")
    }
}

/// Stable Agent instructions section captured for the Turn.
struct AgentInstructionsContext: RuntimePromptProducer {
    let instructions: String

    init(_ instructions: String) {
        self.instructions = instructions
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.text(
            id: "agent.instructions",
            role: .system,
            priority: 94,
            estimatedTokens: TokenEstimator.estimate(text: instructions),
            cachePolicy: .stable,
            path: ["prompt", "AgentInstructionsContext", "SystemPrompt", "stable", "agent.instructions"],
            render: { [instructions] in instructions }
        )]
    }
}

/// Semi-stable Agent continuity items selected by the authoritative context source.
struct AgentMemoryContext: RuntimePromptProducer {
    let memories: [AgentContextMemory]

    init(_ memories: [AgentContextMemory]) {
        self.memories = memories
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.text(
            id: "agent.memory",
            role: .context,
            priority: 88,
            estimatedTokens: TokenEstimator.estimate(parts: memories.map(\.content)),
            compression: .summarize,
            cachePolicy: .semiStable,
            path: ["prompt", "AgentMemoryContext", "TextPrompt", "semiStable", "agent.memory"],
            render: { [memories] in
                guard !memories.isEmpty else { return nil }
                let content = memories.map { memory in
                    if let source = memory.source {
                        return "[\(source)]\n\(memory.content)"
                    }
                    return memory.content
                }.joined(separator: "\n\n")
                return "## Agent Continuity\n\n\(content)"
            }
        )]
    }
}

/// Compact catalog of discoverable Agent Notes. Full file contents stay out of the prompt until
/// the model requests them through the generic workspace file tools.
struct AgentResourceCatalogContext: RuntimePromptProducer {
    let resources: [AgentContextResource]

    init(_ resources: [AgentContextResource]) {
        self.resources = resources
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.text(
            id: "agent.resource-catalog",
            role: .context,
            priority: 89,
            estimatedTokens: TokenEstimator.estimate(parts: resources.map { "\($0.path) \($0.description)" }),
            compression: .summarize,
            cachePolicy: .semiStable,
            path: ["prompt", "AgentResourceCatalogContext", "TextPrompt", "semiStable", "agent.resource-catalog"],
            render: { [resources] in
                guard !resources.isEmpty else { return nil }
                let lines = resources.map { "- `\($0.path)`: \($0.description)" }.joined(separator: "\n")
                return "## Agent Notes Catalog\n\nThe following Markdown files are available in the private workspace. Read a file when its contents are relevant; do not assume the catalog is the file contents.\n\n\(lines)"
            }
        )]
    }
}

/// Semi-stable optional summary of the Agent-owned primary Timeline.
struct AgentPrimaryTimelineSummaryContext: RuntimePromptProducer {
    let summary: String?

    init(_ summary: String?) {
        self.summary = summary
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.text(
            id: "agent.primary-timeline-summary",
            role: .context,
            priority: 87,
            estimatedTokens: TokenEstimator.estimate(text: summary ?? ""),
            cachePolicy: .semiStable,
            path: ["prompt", "AgentPrimaryTimelineSummaryContext", "TextPrompt", "semiStable", "agent.primary-timeline-summary"],
            render: { [summary] in summary }
        )]
    }
}

/// Runtime-owned current Timeline section.
struct TimelineContext: RuntimePromptProducer {
    let timeline: TimelineRecord
    var timelineTitle: String { timeline.title }

    init(_ timeline: TimelineRecord) {
        self.timeline = timeline
    }

    func makeSections() -> [PromptSection] {
        [RuntimePromptSectionFactory.text(
            id: "timeline_context",
            role: .context,
            priority: 72,
            estimatedTokens: TokenEstimator.estimate(text: timeline.title) + 20,
            cachePolicy: .semiStable,
            path: ["prompt", "TimelineContext", "TextPrompt", "semiStable", "timeline_context"],
            render: { [timeline] in
                """
                ## Current Timeline
                - ID: `\(timeline.id.uuidString)`
                - Title: \(timeline.title)
                """
            }
        )]
    }
}
