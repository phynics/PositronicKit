import Foundation

/// Represents an agent definition in the system, consisting of instructions and prompts.
public struct AgentTemplate: Codable, Sendable, Identifiable, Equatable {
    /// Unique identifier for the agent (e.g. "default", "coder")
    public let id: UUID

    /// Display name of the agent
    public var name: String

    /// Description of the agent's purpose
    public var description: String

    /// The core instructions for the agent
    public var systemPrompt: String

    /// Optional: Adds tone, voice, and personality
    public var personaPrompt: String?

    /// Optional: Behavioral constraints and safety rules
    public var guardrailsPrompt: String?

    /// Timestamp when the agent was created
    public let createdAt: Date

    /// Timestamp when the agent was last updated
    public var updatedAt: Date

    /// Optional seed files to write into a new AgentInstance's workspace Notes/ directory.
    /// Keys are filenames (e.g. "system.md"), values are file contents.
    /// Used only at instance creation time.
    public var workspaceFilesSeed: [String: String]?

    public init(
        id: UUID,
        name: String,
        description: String,
        systemPrompt: String,
        personaPrompt: String? = nil,
        guardrailsPrompt: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        workspaceFilesSeed: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.personaPrompt = personaPrompt
        self.guardrailsPrompt = guardrailsPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workspaceFilesSeed = workspaceFilesSeed
    }
}

public extension AgentTemplate {
    /// Composed full system instructions for the LLM
    var composedInstructions: String {
        var parts = [systemPrompt]

        if let persona = personaPrompt, !persona.isEmpty {
            parts.append("## Persona\n" + persona)
        }

        if let guardrails = guardrailsPrompt, !guardrails.isEmpty {
            parts.append("## Guardrails\n" + guardrails)
        }

        return parts.joined(separator: "\n\n")
    }
}
