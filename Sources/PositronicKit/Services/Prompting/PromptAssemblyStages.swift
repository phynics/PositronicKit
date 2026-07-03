import Foundation
import PKPrompt
import PKShared

// MARK: - Standard Assembly Stages

/// Appends system instructions to the prompt.
/// Retrieves instructions from the request or falls back to default system instructions.
struct SystemInstructionsStage: PromptAssemblyStage {
    init() {}

    func execute(_ context: PromptAssemblyContext) async throws {
        let request = context.request
        let instructions = request.systemInstructions ?? DefaultInstructions.system()
        await context.append(SystemInstructions(instructions))
    }
}

/// Appends agent context and timeline title to the prompt.
/// Provides identity information about the agent performing the request.
struct AgentContextStage: PromptAssemblyStage {
    init() {}

    func execute(_ context: PromptAssemblyContext) async throws {
        if let agent = context.agentInstance {
            let timelineTitle = context.timeline?.title
            await context.append(AgentContext(agent, timelineTitle: timelineTitle))
        }
    }
}

/// Appends context notes to the prompt.
/// Injects gathered notes (short-term memories or local file context) into the prompt.
struct ContextNotesStage: PromptAssemblyStage {
    init() {}

    func execute(_ context: PromptAssemblyContext) async throws {
        let notes = context.request.contextNotes
        await context.append(ContextNotes(notes))
    }
}

/// Appends memories to the prompt.
/// Injects retrieved long-term memories from the semantic store.
struct MemoriesStage: PromptAssemblyStage {
    init() {}

    func execute(_ context: PromptAssemblyContext) async throws {
        let memories = context.request.memories
        await context.append(Memories(memories))
    }
}

/// Appends tools to the prompt.
/// Provides descriptions of available tools the agent can invoke.
struct ToolsStage: PromptAssemblyStage {
    init() {}

    func execute(_ context: PromptAssemblyContext) async throws {
        let tools = context.request.tools
        await context.append(Tools(tools))
    }
}

/// Appends workspace and request-origin context to the prompt.
/// Provides information about the file system environment and the requesting origin.
struct WorkspacesContextStage: PromptAssemblyStage {
    init() {}

    func execute(_ context: PromptAssemblyContext) async throws {
        let request = context.request
        await context.append(WorkspacesContext(
            workspaces: request.workspaces,
            primaryWorkspace: request.primaryWorkspace,
            requestOriginName: request.requestOriginName
        ))
    }
}

/// Appends timeline context to the prompt.
/// Injects metadata about the current conversation thread.
struct TimelineContextStage: PromptAssemblyStage {
    init() {}

    func execute(_ context: PromptAssemblyContext) async throws {
        if let timeline = context.timeline {
            await context.append(TimelineContext(timeline))
        }
    }
}

/// Appends optimized chat history to the prompt.
/// Truncates conversation history based on token budgets before appending.
struct ChatHistoryStage: PromptAssemblyStage {
    init() {}

    func execute(_ context: PromptAssemblyContext) async throws {
        let history = context.request.chatHistory
        let optimized = PromptHistoryOptimizer.optimizeForDefaultBudget(history)
        await context.append(ChatHistory(optimized))
    }
}

/// Appends the user's latest query to the prompt.
/// Typically the final section of the prompt.
struct UserQueryStage: PromptAssemblyStage {
    init() {}

    func execute(_ context: PromptAssemblyContext) async throws {
        let request = context.request
        await context.append(UserQuery(request.userQuery, turnInstructions: request.turnInstructions))
    }
}

/// Appends extension sections provided in the request context.
/// Allows external plugins to inject custom sections into the assembly process.
struct ExtensionSectionsStage: PromptAssemblyStage {
    init() {}

    func execute(_ context: PromptAssemblyContext) async throws {
        let sections = context.extensionSections
        await context.append(sections)
    }
}
