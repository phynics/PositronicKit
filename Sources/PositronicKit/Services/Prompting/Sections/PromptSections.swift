import Foundation
import PKPrompt
import PKContracts
import PKUtilities

public struct SystemInstructions: Prompt {
    public let instructions: String

    public init(_ instructions: String) {
        self.instructions = instructions
    }

    public var body: some Prompt {
        if !instructions.isEmpty {
            SystemPrompt(
                """
                # System Instructions

                \(instructions)
                """,
                estimatedTokens: TokenEstimator.estimate(text: instructions)
            )
        } else {
            EmptyPrompt()
        }
    }
}

public struct Tools: Prompt {
    public let tools: [AnyTool]

    public init(_ tools: [AnyTool]) {
        self.tools = tools
    }

    public var body: some Prompt {
        TextPrompt(
            id: "tools",
            priority: 80,
            compression: .keep,
            cachePolicy: .semiStable,
            estimatedTokens: tools.count * 50,
            render: renderContent
        )
    }

    private func renderContent() async -> String? {
        guard !tools.isEmpty else { return nil }
        return await tools.formattedForPrompt()
    }
}

public struct ChatHistory: Prompt {
    public let messages: [Message]

    public init(_ messages: [Message]) {
        self.messages = messages
    }

    public var body: some Prompt {
        HistoryPrompt(messages)
    }

    public func constrained(to tokens: Int) -> ChatHistory {
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
    public var estimatedTokens: Int {
        TokenEstimator.estimate(parts: messages.map(\.content))
    }
}

/// Bounded host-provided values captured for one Turn.
public struct TurnContextContributions: Prompt {
    public let contributions: [TurnContextContribution]

    public init(_ contributions: [TurnContextContribution]) {
        self.contributions = contributions
    }

    public var body: some Prompt {
        TextPrompt(
            id: "turn.context-contributions",
            priority: 89,
            compression: .truncate(keeping: .head),
            cachePolicy: .volatile,
            estimatedTokens: TokenEstimator.estimate(parts: contributions.map { $0.value.textValue }),
            render: renderContent
        )
    }

    private func renderContent() async -> String? {
        guard !contributions.isEmpty else { return nil }
        let values = contributions.map { contribution in
            "[\(contribution.namespace).\(contribution.key)]\n\(contribution.value.textValue)"
        }.joined(separator: "\n\n")
        return "## Turn Context\n\n\(values)"
    }
}
public struct UserQuery: Prompt {
    public let content: MessageContent
    public var query: String { content.text }
    /// Optional per-turn instructions rendered after the query inside the same
    /// `.userQuery` section (single-section invariant preserved; volatile cache policy).
    public let turnInstructions: String?

    public init(_ query: String, turnInstructions: String? = nil) {
        content = MessageContent(query)
        self.turnInstructions = turnInstructions
    }

    public init(_ content: MessageContent, turnInstructions: String? = nil) {
        self.content = content
        self.turnInstructions = turnInstructions
    }

    public var body: some Prompt {
        let resolved: MessageContent = {
            guard let turnInstructions, !turnInstructions.isEmpty else { return content }
            return MessageContent(parts: content.parts + [.text("\n" + turnInstructions)])
        }()
        UserPrompt(resolved, estimatedTokens: resolved.estimatedTokens)
    }
}

public struct WorkspacesContext: Prompt {
    public let workspaces: [WorkspaceReference]
    public let primaryWorkspace: WorkspaceReference?
    public let requestOriginName: String?

    public init(
        workspaces: [WorkspaceReference],
        primaryWorkspace: WorkspaceReference?,
        requestOriginName: String?
    ) {
        self.workspaces = workspaces
        self.primaryWorkspace = primaryWorkspace
        self.requestOriginName = requestOriginName
    }

    public var body: some Prompt {
        TextPrompt(
            id: "workspaces",
            priority: 75,
            compression: .keep,
            cachePolicy: .semiStable,
            estimatedTokens: estimatedTokens,
            render: renderContent
        )
    }

    private func renderContent() async -> String? {
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

public struct AgentContext: Prompt {
    public let snapshot: AgentContextSnapshot
    public let threadTitle: String?

    public init(_ agent: Agent, threadTitle: String? = nil) {
        self.snapshot = AgentContextSnapshot(agent: agent)
        self.threadTitle = threadTitle
    }

    public init(_ snapshot: AgentContextSnapshot, threadTitle: String? = nil) {
        self.snapshot = snapshot
        self.threadTitle = threadTitle
    }

    public var body: some Prompt {
        AgentIdentityContext(snapshot: snapshot, threadTitle: threadTitle)
    }

    /// Retained as a compact compatibility wrapper; the runtime uses the four reserved
    /// sections below so each stable/semi-stable portion can be journaled independently.
    private var text: String {
        [
            "## Your Identity",
            "You are **\(snapshot.identity.name)**.",
            snapshot.identity.description.isEmpty ? nil : "Description: \(snapshot.identity.description)",
            threadTitle.map { "Currently operating on thread: \"\($0)\"" },
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Stable Agent identity section owned by the runtime.
public struct AgentIdentityContext: Prompt {
    public let snapshot: AgentContextSnapshot
    public let threadTitle: String?

    public init(snapshot: AgentContextSnapshot, threadTitle: String? = nil) {
        self.snapshot = snapshot
        self.threadTitle = threadTitle
    }

    public var body: some Prompt {
        SystemPrompt(
            text,
            id: "agent.identity",
            priority: 95,
            estimatedTokens: TokenEstimator.estimate(text: text)
        )
    }

    private var text: String {
        var lines = ["## Your Identity", "You are **\(snapshot.identity.name)**."]
        if !snapshot.identity.description.isEmpty {
            lines.append("Description: \(snapshot.identity.description)")
        }
        if let threadTitle {
            lines.append("Currently operating on thread: \"\(threadTitle)\"")
        }
        lines.append("Your private workspace supplies persistent continuity (`Notes/` directory).")
        return lines.joined(separator: "\n")
    }
}

/// Stable Agent instructions section captured for the Turn.
public struct AgentInstructionsContext: Prompt {
    public let instructions: String

    public init(_ instructions: String) {
        self.instructions = instructions
    }

    public var body: some Prompt {
        SystemPrompt(
            instructions,
            id: "agent.instructions",
            priority: 94,
            estimatedTokens: TokenEstimator.estimate(text: instructions)
        )
    }
}

/// Semi-stable Agent continuity items selected by the authoritative context source.
public struct AgentMemoryContext: Prompt {
    public let memories: [AgentContextMemory]

    public init(_ memories: [AgentContextMemory]) {
        self.memories = memories
    }

    public var body: some Prompt {
        TextPrompt(
            id: "agent.memory",
            priority: 88,
            compression: .summarize,
            cachePolicy: .semiStable,
            estimatedTokens: TokenEstimator.estimate(parts: memories.map(\.content)),
            render: renderContent
        )
    }

    private func renderContent() async -> String? {
        guard !memories.isEmpty else { return nil }
        let content = memories.map { memory in
            if let source = memory.source {
                return "[\(source)]\n\(memory.content)"
            }
            return memory.content
        }.joined(separator: "\n\n")
        return "## Agent Continuity\n\n\(content)"
    }
}

/// Semi-stable optional summary of the Agent-owned primary Thread.
public struct AgentPrimaryThreadSummaryContext: Prompt {
    public let summary: String?

    public init(_ summary: String?) {
        self.summary = summary
    }

    public var body: some Prompt {
        TextPrompt(
            summary ?? "",
            id: "agent.primary-thread-summary",
            priority: 87,
            cachePolicy: .semiStable,
            estimatedTokens: TokenEstimator.estimate(text: summary ?? "")
        )
    }

}

public struct ThreadContext: Prompt {
    public let thread: Thread
    public var threadTitle: String { thread.title }

    public init(_ thread: Thread) {
        self.thread = thread
    }

    public var body: some Prompt {
        TextPrompt(
            """
            ## Current Thread
            - ID: `\(thread.id.uuidString)`
            - Title: \(thread.title)
            """,
            id: "thread_context",
            priority: 72,
            cachePolicy: .semiStable,
            estimatedTokens: TokenEstimator.estimate(text: thread.title) + 20
        )
    }
}
