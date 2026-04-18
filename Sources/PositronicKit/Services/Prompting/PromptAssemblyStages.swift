import Foundation
import PKPrompt
import PKShared

// MARK: - Standard Assembly Stages

/// Appends system instructions to the prompt.
/// Retrieves instructions from the request or falls back to default system instructions.
public struct SystemInstructionsStage: PromptAssemblyStage {
    /// Initializes a new system instructions stage.
    public init() {}
    
    /// Appends system instructions from the request or default instructions to the context.
    /// - Parameter context: The shared assembly context.
    public func execute(_ context: PromptAssemblyContext) async throws {
        let request = context.request
        let instructions = request.systemInstructions ?? DefaultInstructions.system()
        await context.append(SystemInstructions(instructions))
    }
}

/// Appends agent context and timeline title to the prompt.
/// Provides identity information about the agent performing the request.
public struct AgentContextStage: PromptAssemblyStage {
    /// Initializes a new agent context stage.
    public init() {}
    
    /// Appends agent instance and timeline title information to the context.
    /// - Parameter context: The shared assembly context.
    public func execute(_ context: PromptAssemblyContext) async throws {
        if let agent = context.agentInstance {
            let timelineTitle = context.timeline?.title
            await context.append(AgentContext(agent, timelineTitle: timelineTitle))
        }
    }
}

/// Appends context notes to the prompt.
/// Injects gathered notes (short-term memories or local file context) into the prompt.
public struct ContextNotesStage: PromptAssemblyStage {
    /// Initializes a new context notes stage.
    public init() {}
    
    /// Appends discovered notes from the request to the context.
    /// - Parameter context: The shared assembly context.
    public func execute(_ context: PromptAssemblyContext) async throws {
        let notes = context.request.contextNotes
        await context.append(ContextNotes(notes))
    }
}

/// Appends memories to the prompt.
/// Injects retrieved long-term memories from the semantic store.
public struct MemoriesStage: PromptAssemblyStage {
    /// Initializes a new memories stage.
    public init() {}
    
    /// Appends retrieved memories from the request to the context.
    /// - Parameter context: The shared assembly context.
    public func execute(_ context: PromptAssemblyContext) async throws {
        let memories = context.request.memories
        await context.append(Memories(memories))
    }
}

/// Appends tools to the prompt.
/// Provides descriptions of available tools the agent can invoke.
public struct ToolsStage: PromptAssemblyStage {
    /// Initializes a new tools stage.
    public init() {}
    
    /// Appends available tools from the request to the context.
    /// - Parameter context: The shared assembly context.
    public func execute(_ context: PromptAssemblyContext) async throws {
        let tools = context.request.tools
        await context.append(Tools(tools))
    }
}

/// Appends workspace and client context to the prompt.
/// Provides information about the file system environment and the requesting client.
public struct WorkspacesContextStage: PromptAssemblyStage {
    /// Initializes a new workspaces context stage.
    public init() {}
    
    /// Appends workspace and client information to the context.
    /// - Parameter context: The shared assembly context.
    public func execute(_ context: PromptAssemblyContext) async throws {
        let request = context.request
        await context.append(WorkspacesContext(
            workspaces: request.workspaces,
            primaryWorkspace: request.primaryWorkspace,
            clientName: request.clientName
        ))
    }
}

/// Appends timeline context to the prompt.
/// Injects metadata about the current conversation thread.
public struct TimelineContextStage: PromptAssemblyStage {
    /// Initializes a new timeline context stage.
    public init() {}
    
    /// Appends timeline information to the context if available.
    /// - Parameter context: The shared assembly context.
    public func execute(_ context: PromptAssemblyContext) async throws {
        if let timeline = context.timeline {
            await context.append(TimelineContext(timeline))
        }
    }
}

/// Appends optimized chat history to the prompt.
/// Truncates conversation history based on token budgets before appending.
public struct ChatHistoryStage: PromptAssemblyStage {
    /// Initializes a new chat history stage.
    public init() {}
    
    /// Optimizes and appends conversation history to the context.
    /// - Parameter context: The shared assembly context.
    public func execute(_ context: PromptAssemblyContext) async throws {
        let history = context.request.chatHistory
        let optimized = PromptHistoryOptimizer.optimizeForDefaultBudget(history)
        await context.append(ChatHistory(optimized))
    }
}

/// Appends the user's latest query to the prompt.
/// Typically the final section of the prompt.
public struct UserQueryStage: PromptAssemblyStage {
    /// Initializes a new user query stage.
    public init() {}
    
    /// Appends the latest user query to the context.
    /// - Parameter context: The shared assembly context.
    public func execute(_ context: PromptAssemblyContext) async throws {
        let query = context.request.userQuery
        await context.append(UserQuery(query))
    }
}

/// Appends extension sections provided in the request context.
/// Allows external plugins to inject custom sections into the assembly process.
public struct ExtensionSectionsStage: PromptAssemblyStage {
    /// Initializes a new extension sections stage.
    public init() {}
    
    /// Appends any additional sections provided by extensions to the context.
    /// - Parameter context: The shared assembly context.
    public func execute(_ context: PromptAssemblyContext) async throws {
        let sections = context.extensionSections
        await context.append(sections)
    }
}
