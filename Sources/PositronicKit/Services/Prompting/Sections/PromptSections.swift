import Foundation
import PKPrompt
import PKShared

public struct SystemInstructions: PrimitiveContextSection {
    public let id = "system"
    public let role: PromptSectionRole = .system
    public let priority = 100
    public let cachePolicy: CachePolicy = .stable
    public let compression: CompressionStrategy = .keep
    public let type: ContextSectionType = .text
    public let instructions: String

    public init(_ instructions: String) {
        self.instructions = instructions
    }

    public func renderContent() async -> String? {
        guard !instructions.isEmpty else { return nil }
        return """
        # System Instructions

        \(instructions)
        """
    }

    public var estimatedTokens: Int {
        TokenEstimator.estimate(text: instructions)
    }
}

public struct Memories: PrimitiveContextSection {
    public let id = "memories"
    public let role: PromptSectionRole = .context
    public let priority = 85
    public let cachePolicy: CachePolicy = .volatile
    public let compression: CompressionStrategy = .summarize
    public let type: ContextSectionType = .list
    public let memories: [Memory]
    public let summarizedContent: String?

    public init(_ memories: [Memory], summarizedContent: String? = nil) {
        self.memories = memories
        self.summarizedContent = summarizedContent
    }

    public func renderContent() async -> String? {
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

    public var estimatedTokens: Int {
        if let summary = summarizedContent {
            return TokenEstimator.estimate(text: summary)
        }
        return TokenEstimator.estimate(parts: memories.map(\.content))
    }
}

public struct Tools: PrimitiveContextSection {
    public let id = "tools"
    public let role: PromptSectionRole = .context
    public let priority = 80
    public let cachePolicy: CachePolicy = .semiStable
    public let compression: CompressionStrategy = .keep
    public let type: ContextSectionType = .list
    public let tools: [AnyTool]

    public init(_ tools: [AnyTool]) {
        self.tools = tools
    }

    public func renderContent() async -> String? {
        guard !tools.isEmpty else { return nil }
        return await formatToolsForPrompt(tools)
    }

    public var estimatedTokens: Int {
        tools.count * 50
    }
}

public struct ChatHistory: PrimitiveContextSection {
    public let id = "chat_history"
    public let role: PromptSectionRole = .chatHistory
    public let priority = 70
    public let cachePolicy: CachePolicy = .volatile
    public let compression: CompressionStrategy = .truncate(tail: false)
    public let type: ContextSectionType = .list
    public let messages: [Message]

    public init(_ messages: [Message]) {
        self.messages = messages
    }

    public var historyMessages: [Message]? {
        messages
    }

    public func renderContent() async -> String? {
        nil
    }

    public var estimatedTokens: Int {
        TokenEstimator.estimate(parts: messages.map(\.content))
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
}

public struct ContextNotes: PrimitiveContextSection {
    public let id = "context_notes"
    public let role: PromptSectionRole = .context
    public let priority = 90
    public let cachePolicy: CachePolicy = .volatile
    public let compression: CompressionStrategy = .truncate(tail: true)
    public let type: ContextSectionType = .list
    public let notes: [ContextFile]

    public init(_ notes: [ContextFile]) {
        self.notes = notes
    }

    public func renderContent() async -> String? {
        guard !notes.isEmpty else { return nil }

        let notesText = notes.map { note in
            """
            [File: \(note.name) (\(note.source))]
            \(note.content)
            """
        }.joined(separator: "\n\n")

        return """
        The following context files contain important information about the user, \
        the project, and your persona. Use them to provide accurate and personalized responses.

        You can edit or create new files in the `Notes/` directory to store long-term information.

        \(notesText)
        """
    }

    public var estimatedTokens: Int {
        TokenEstimator.estimate(parts: notes.map(\.content))
    }
}

public struct UserQuery: PrimitiveContextSection {
    public let id = "user_query"
    public let role: PromptSectionRole = .userQuery
    public let priority = 10
    public let cachePolicy: CachePolicy = .volatile
    public let compression: CompressionStrategy = .keep
    public let type: ContextSectionType = .text
    public let query: String

    public init(_ query: String) {
        self.query = query
    }

    public func renderContent() async -> String? {
        guard !query.isEmpty else { return nil }
        return query
    }

    public var estimatedTokens: Int {
        TokenEstimator.estimate(text: query)
    }
}

public struct WorkspacesContext: PrimitiveContextSection {
    public let id = "workspaces"
    public let role: PromptSectionRole = .context
    public let priority = 75
    public let cachePolicy: CachePolicy = .semiStable
    public let compression: CompressionStrategy = .keep
    public let type: ContextSectionType = .text
    public let workspaces: [WorkspaceReference]
    public let primaryWorkspace: WorkspaceReference?
    public let clientName: String?

    public init(
        workspaces: [WorkspaceReference],
        primaryWorkspace: WorkspaceReference?,
        clientName: String?
    ) {
        self.workspaces = workspaces
        self.primaryWorkspace = primaryWorkspace
        self.clientName = clientName
    }

    public func renderContent() async -> String? {
        var output = ""

        if let clientName {
            output += "User Query Origin: **\(clientName)**\n\n"
        }

        let allWorkspaces = (primaryWorkspace.map { [$0] } ?? []) + workspaces.filter { $0.id != primaryWorkspace?.id }
        guard !allWorkspaces.isEmpty else { return output.isEmpty ? nil : output }

        output += "## Available Workspaces\n"
        output += "You have access to the following attached workspaces natively within this session:\n\n"

        for workspace in allWorkspaces {
            let isPrimary = workspace.id == primaryWorkspace?.id

            output.append("- Workspace ID: `")
            output.append(workspace.id.uuidString)
            output.append("`\n  Location: `")
            output.append(workspace.uri.description)
            output.append("`\n  Environment: ")
            output.append(isPrimary ? "Primary\n" : "External\n")

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
        output += "1. All file paths passed to tools MUST be relative to the targeted workspace root.\n"
        output += "2. **IMPORTANT**: If multiple workspaces provide the same tool (e.g. `ls`, `cat`, `grep`), you MUST provide the `workspaceID` argument in your tool call to specify which workspace to use. If omitted, the system will use a default priority that may not match your intent.\n"
        output += "\nWhen a user asks you to operate on files or perform actions in these workspaces, you can use the appropriate tools with the workspace's URI or ID.\n"

        return output
    }

    public var estimatedTokens: Int {
        TokenEstimator.estimate(text: "Workspaces section placeholder") + workspaces.count * 50
    }
}

public struct AgentContext: PrimitiveContextSection {
    public let id = "agent_context"
    public let role: PromptSectionRole = .system
    public let priority = 95
    public let cachePolicy: CachePolicy = .stable
    public let compression: CompressionStrategy = .keep
    public let type: ContextSectionType = .text
    public let agent: AgentInstance
    public let timelineTitle: String?

    public init(_ agent: AgentInstance, timelineTitle: String? = nil) {
        self.agent = agent
        self.timelineTitle = timelineTitle
    }

    public func renderContent() async -> String? {
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

    public var estimatedTokens: Int {
        TokenEstimator.estimate(text: agent.name + agent.description) + 30
    }
}

public struct TimelineContext: PrimitiveContextSection {
    public let id = "timeline_context"
    public let role: PromptSectionRole = .context
    public let priority = 72
    public let cachePolicy: CachePolicy = .semiStable
    public let compression: CompressionStrategy = .keep
    public let type: ContextSectionType = .text
    public let timeline: Timeline

    public init(_ timeline: Timeline) {
        self.timeline = timeline
    }

    public func renderContent() async -> String? {
        """
        ## Current Timeline
        - ID: `\(timeline.id.uuidString)`
        - Title: \(timeline.title)
        """
    }

    public var estimatedTokens: Int {
        TokenEstimator.estimate(text: timeline.title) + 20
    }
}
