import Foundation
import PKPrompt
import PKShared

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
                estimatedTokens: PKShared.TokenEstimator.estimate(text: instructions)
            )
        } else {
            EmptyPrompt()
        }
    }
}

public struct Memories: Prompt {
    public let memories: [Memory]
    public let summarizedContent: String?

    public init(_ memories: [Memory], summarizedContent: String? = nil) {
        self.memories = memories
        self.summarizedContent = summarizedContent
    }

    public var body: some Prompt {
        TextPrompt(
            id: "memories",
            priority: 85,
            compression: .summarize,
            cachePolicy: .volatile,
            estimatedTokens: estimatedTokens,
            render: renderContent
        )
    }

    private func renderContent() async -> String? {
        if let summary = summarizedContent {
            return """
            === MEMORY CONTEXT (SUMMARIZED) ===
            \(summary)
            """
        }

        guard !memories.isEmpty else { return nil }
        return """
        Found \(memories.count) relevant memories:

        \(memories.promptContent)
        """
    }

    private var estimatedTokens: Int {
        if let summary = summarizedContent {
            return PKShared.TokenEstimator.estimate(text: summary)
        }
        return PKShared.TokenEstimator.estimate(parts: memories.map(\.content))
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
            let count = PKShared.TokenEstimator.estimate(text: message.content) + 10
            if accumulated + count > tokens {
                break
            }
            accumulated += count
            keepCount += 1
        }

        return ChatHistory(Array(messages.suffix(keepCount)))
    }

    public var estimatedTokens: Int {
        PKShared.TokenEstimator.estimate(parts: messages.map(\.content))
    }
}

public struct ContextNotes: Prompt {
    public let notes: [ContextFile]

    public init(_ notes: [ContextFile]) {
        self.notes = notes
    }

    public var body: some Prompt {
        TextPrompt(
            id: "context_notes",
            priority: 90,
            compression: .truncate(tail: true),
            cachePolicy: .volatile,
            estimatedTokens: PKShared.TokenEstimator.estimate(parts: notes.map(\.content)),
            render: renderContent
        )
    }

    private func renderContent() async -> String? {
        guard !notes.isEmpty else { return nil }

        let notesText = notes.map { note in
            """
            [File: \(note.name) (\(note.source))]
            \(note.content)
            """
        }.joined(separator: "\n\n")

        return """
        Context files (edit or add files under `Notes/` to persist long-term information):

        \(notesText)
        """
    }
}

public struct UserQuery: Prompt {
    public let query: String
    /// Optional per-turn instructions rendered after the query inside the same
    /// `.userQuery` section (single-section invariant preserved; volatile cache policy).
    public let turnInstructions: String?

    public init(_ query: String, turnInstructions: String? = nil) {
        self.query = query
        self.turnInstructions = turnInstructions
    }

    public var body: some Prompt {
        let text: String = {
            guard let turnInstructions, !turnInstructions.isEmpty else { return query }
            return query + "\n" + turnInstructions
        }()
        UserPrompt(text, estimatedTokens: PKShared.TokenEstimator.estimate(text: text))
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
                    output.append(tool.toolId)
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
        PKShared.TokenEstimator.estimate(text: "Workspaces section placeholder") + workspaces.count * 50
    }
}

public struct AgentContext: Prompt {
    public let agent: AgentInstance
    public let timelineTitle: String?

    public init(_ agent: AgentInstance, timelineTitle: String? = nil) {
        self.agent = agent
        self.timelineTitle = timelineTitle
    }

    public var body: some Prompt {
        SystemPrompt(
            text,
            id: "agent_context",
            priority: 95,
            estimatedTokens: PKShared.TokenEstimator.estimate(text: agent.name + agent.description) + 30
        )
    }

    private var text: String {
        var lines: [String] = [
            "## Your Identity",
            "You are **\(agent.name)**.",
        ]
        if !agent.description.isEmpty {
            lines.append("Description: \(agent.description)")
        }
        if let timelineTitle {
            lines.append("Currently operating on timeline: \"\(timelineTitle)\"")
        }
        lines.append("Your private workspace contains your persistent memory (`Notes/` directory).")
        return lines.joined(separator: "\n")
    }
}

public struct TimelineContext: Prompt {
    public let timeline: Timeline

    public init(_ timeline: Timeline) {
        self.timeline = timeline
    }

    public var body: some Prompt {
        TextPrompt(
            """
            ## Current Timeline
            - ID: `\(timeline.id.uuidString)`
            - Title: \(timeline.title)
            """,
            id: "timeline_context",
            priority: 72,
            cachePolicy: .semiStable,
            estimatedTokens: PKShared.TokenEstimator.estimate(text: timeline.title) + 20
        )
    }
}
