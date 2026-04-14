import Foundation
import PKPrompt
import PKShared

/// A section containing primary system instructions.
public struct SystemInstructions: ContextSection {
    public let id = "system"
    public let priority = 100
    public let cachePolicy: CachePolicy = .stable
    public let strategy: CompressionStrategy = .keep
    public let type: ContextSectionType = .text
    public let instructions: String

    /// Initializes a new system instructions section.
    /// - Parameter instructions: The instruction content.
    public init(_ instructions: String) {
        self.instructions = instructions
    }

    /// Renders the instructions with a standardized header.
    /// - Returns: A formatted string containing the system instructions.
    public func render() async -> String? {
        guard !instructions.isEmpty else { return nil }
        return """
        # System Instructions

        \(instructions)
        """
    }

    /// Estimates the token count for the instructions.
    public var estimatedTokens: Int {
        TokenEstimator.estimate(text: instructions)
    }
}

/// A section containing retrieved semantic memories.
public struct Memories: ContextSection {
    public let id = "memories"
    public let priority = 85
    public let cachePolicy: CachePolicy = .volatile
    public let strategy: CompressionStrategy = .summarize
    public let type: ContextSectionType = .list
    public let memories: [Memory]
    public let summarizedContent: String?

    /// Initializes a new memories section.
    /// - Parameters:
    ///   - memories: The array of retrieved memories.
    ///   - summarizedContent: Optional pre-summarized text.
    public init(_ memories: [Memory], summarizedContent: String? = nil) {
        self.memories = memories
        self.summarizedContent = summarizedContent
    }

    /// Renders the memories into a list format or summary.
    /// - Returns: A formatted string of memories or nil if empty.
    public func render() async -> String? {
        if let summary = summarizedContent {
            return """
            === MEMORY CONTEXT (SUMMARIZED) ===
            \(summary)
            """
        }

        if memories.isEmpty { return nil }

        return """
        Found \(memories.count) relevant memories:

        \(memories.promptContent)
        """
    }

    /// Estimates the total token count for the memories.
    public var estimatedTokens: Int {
        if let summary = summarizedContent {
            return TokenEstimator.estimate(text: summary)
        }
        return TokenEstimator.estimate(parts: memories.map(\.content))
    }
}

/// A section describing available tools for the agent.
public struct Tools: ContextSection {
    public let id = "tools"
    public let priority = 80
    public let cachePolicy: CachePolicy = .semiStable
    public let strategy: CompressionStrategy = .keep
    public let type: ContextSectionType = .list
    public let tools: [AnyTool]

    /// Initializes a new tools section.
    /// - Parameter tools: The tools to describe.
    public init(_ tools: [AnyTool]) {
        self.tools = tools
    }

    /// Renders the tool descriptions using standardized formatting.
    /// - Returns: A formatted string of tool definitions.
    public func render() async -> String? {
        guard !tools.isEmpty else { return nil }
        return await formatToolsForPrompt(tools)
    }

    /// Estimates the token count for the tool descriptions.
    public var estimatedTokens: Int {
        tools.count * 50 // Rough estimate per tool definition
    }
}

/// A section containing conversation history.
public struct ChatHistory: ContextSection {
    public let id = "chat_history"
    public let priority = 70
    public let cachePolicy: CachePolicy = .volatile
    public let strategy: CompressionStrategy = .truncate(tail: false)
    public let type: ContextSectionType = .list
    public let messages: [Message]

    /// Initializes a new chat history section.
    /// - Parameter messages: The messages to include.
    public init(_ messages: [Message]) {
        self.messages = messages
    }

    /// Renders the history into text for raw prompts or debugging.
    /// Note: Actual LLM calls usually pass history as a structured message array.
    /// - Returns: A formatted conversation string or nil if empty.
    public func render() async -> String? {
        return nil // History rendering is usually handled via structured messages
    }

    /// Estimates the total token count for the message history.
    public var estimatedTokens: Int {
        TokenEstimator.estimate(parts: messages.map(\.content))
    }

    /// Returns a new version of this section constrained to a token budget.
    /// - Parameter tokens: The maximum allowed tokens.
    /// - Returns: A truncated chat history section.
    public func constrained(to tokens: Int) -> ContextSection {
        guard estimatedTokens > tokens else { return self }

        var accumulated = 0
        var keepCount = 0

        // Keep newest messages first (iterate backwards)
        for message in messages.reversed() {
            let count = TokenEstimator.estimate(text: message.content) + 10
            if accumulated + count > tokens {
                break
            }
            accumulated += count
            keepCount += 1
        }

        let subset = Array(messages.suffix(keepCount))
        return ChatHistory(subset)
    }
}

/// A section containing temporary notes or local file context.
public struct ContextNotes: ContextSection {
    public let id = "context_notes"
    public let priority = 90
    public let cachePolicy: CachePolicy = .volatile
    public let strategy: CompressionStrategy = .truncate(tail: true)
    public let type: ContextSectionType = .list
    public let notes: [ContextFile]

    /// Initializes a new context notes section.
    /// - Parameter notes: The context files to include.
    public init(_ notes: [ContextFile]) {
        self.notes = notes
    }

    /// Renders the notes with standardized file headers.
    /// - Returns: A formatted string of notes or nil if empty.
    public func render() async -> String? {
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

    /// Renders the notes constrained to a specific token budget.
    /// - Parameter tokens: Maximum tokens allowed.
    /// - Returns: A potentially truncated string of notes.
    public func render(constrainedTo tokens: Int?) async -> String? {
        guard let tokens = tokens else { return await render() }
        guard var fullText = await render() else { return nil }

        let estimated = TokenEstimator.estimate(text: fullText)
        if estimated <= tokens { return fullText }

        let charLimit = tokens * 4
        if fullText.count > charLimit {
            fullText = String(fullText.prefix(charLimit)) + "\n... [Truncated]"
        }
        return fullText
    }

    /// Estimates the token count for all context notes.
    public var estimatedTokens: Int {
        TokenEstimator.estimate(parts: notes.map(\.content))
    }
}

/// A section containing the user's latest query.
public struct UserQuery: ContextSection {
    public let id = "user_query"
    public let priority = 10
    public let cachePolicy: CachePolicy = .volatile
    public let strategy: CompressionStrategy = .keep
    public let type: ContextSectionType = .text
    public let query: String

    /// Initializes a new user query section.
    /// - Parameter query: The query text.
    public init(_ query: String) {
        self.query = query
    }

    /// Renders the raw user query.
    /// - Returns: The query string or nil if empty.
    public func render() async -> String? {
        guard !query.isEmpty else { return nil }
        return query
    }

    /// Estimates the token count for the query.
    public var estimatedTokens: Int {
        TokenEstimator.estimate(text: query)
    }
}

/// A section describing attached workspaces and routing rules.
public struct WorkspacesContext: ContextSection {
    public let id = "workspaces"
    public let priority = 75
    public let cachePolicy: CachePolicy = .semiStable
    public let strategy: CompressionStrategy = .keep
    public let type: ContextSectionType = .text
    public let workspaces: [WorkspaceReference]
    public let primaryWorkspace: WorkspaceReference?
    public let clientName: String?

    /// Initializes a new workspaces context section.
    /// - Parameters:
    ///   - workspaces: The full list of workspaces.
    ///   - primaryWorkspace: The primary workspace.
    ///   - clientName: The requesting client.
    public init(
        workspaces: [WorkspaceReference], primaryWorkspace: WorkspaceReference?,
        clientName: String?
    ) {
        self.workspaces = workspaces
        self.primaryWorkspace = primaryWorkspace
        self.clientName = clientName
    }

    /// Renders workspace information, routing rules, and tool availability.
    /// - Returns: A formatted string describing the environment.
    public func render() async -> String? {
        var output = ""

        if let clientName = clientName {
            output += "User Query Origin: **\(clientName)**\n\n"
        }

        let allWorkspaces =
            (primaryWorkspace != nil ? [primaryWorkspace!] : []) +
            workspaces.filter { $0.id != primaryWorkspace?.id }

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

            if isPrimary {
                output.append("Primary\n")
            } else {
                output.append("External\n")
            }

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

    /// Estimates the token count for the workspace context.
    public var estimatedTokens: Int {
        TokenEstimator.estimate(text: "Workspaces section placeholder") + workspaces.count * 50
    }
}

/// A section describing the agent's identity and persona.
public struct AgentContext: ContextSection {
    public let id = "agent_context"
    public let priority = 95
    public let cachePolicy: CachePolicy = .stable
    public let strategy: CompressionStrategy = .keep
    public let type: ContextSectionType = .text
    public let agent: AgentInstance
    public let timelineTitle: String?

    /// Initializes a new agent context section.
    /// - Parameters:
    ///   - agent: The agent instance.
    ///   - timelineTitle: Optional timeline name.
    public init(_ agent: AgentInstance, timelineTitle: String? = nil) {
        self.agent = agent
        self.timelineTitle = timelineTitle
    }

    /// Renders the agent's name, description, and current timeline.
    /// - Returns: A formatted string of identity information.
    public func render() async -> String? {
        var lines: [String] = [
            "## Your Identity",
            "You are **\(agent.name)**.",
        ]
        if !agent.description.isEmpty {
            lines.append("Description: \(agent.description)")
        }
        if let title = timelineTitle {
            lines.append("Currently operating on timeline: \"\(title)\"")
        }
        lines.append("Your private workspace contains your persistent memory (`Notes/` directory).")
        return lines.joined(separator: "\n")
    }

    /// Estimates the token count for the identity context.
    public var estimatedTokens: Int {
        TokenEstimator.estimate(text: agent.name + agent.description) + 30
    }
}

/// A section containing metadata about the current conversation timeline.
public struct TimelineContext: ContextSection {
    public let id = "timeline_context"
    public let priority = 72
    public let cachePolicy: CachePolicy = .semiStable
    public let strategy: CompressionStrategy = .keep
    public let type: ContextSectionType = .text
    public let timeline: Timeline

    /// Initializes a new timeline context section.
    /// - Parameter timeline: The timeline data.
    public init(_ timeline: Timeline) {
        self.timeline = timeline
    }

    /// Renders the timeline ID and title.
    /// - Returns: A formatted string of timeline metadata.
    public func render() async -> String? {
        """
        ## Current Timeline
        - ID: `\(timeline.id.uuidString)`
        - Title: \(timeline.title)
        """
    }

    /// Estimates the token count for the timeline metadata.
    public var estimatedTokens: Int {
        TokenEstimator.estimate(text: timeline.title) + 20
    }
}
