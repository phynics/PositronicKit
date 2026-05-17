import Foundation

/// A tool that the LLM can call to interact with workspaces, data, or computations.
///
/// Implement this protocol to add new capabilities to the AI assistant. Tools are automatically
/// registered and exposed to the LLM during context construction.
public protocol Tool: Sendable, PromptFormattable {
    /// Unique identifier for the tool used by the LLM to call it (e.g., "read_file").
    var id: String { get }

    /// Human-readable display name for the tool.
    var name: String { get }

    /// Clear, concise description of what the tool does and when the LLM should use it.
    var description: String { get }

    /// Whether the tool requires explicit user permission before execution.
    /// If true, the system will prompt the user to approve the tool call.
    var requiresPermission: Bool { get }

    /// Example usage of the tool, typically formatted as a JSON string.
    /// Used to provide guidance to the LLM when it makes errors.
    var usageExample: String? { get }

    /// Whether the tool is currently available for execution in the given environment.
    func canExecute() async -> Bool

    /// JSON schema defining the expected parameters for this tool.
    /// Use ``ToolParameterSchema`` to build this in a type-safe way.
    var parametersSchema: [String: AnyCodable] { get }

    /// Executes the tool logic with the parameters provided by the LLM.
    ///
    /// - Parameter parameters: Dictionary of argument names to values.
    /// - Returns: A ``ToolResult`` containing the output or error message.
    ///
    /// Use ``ToolParameters`` to decode and validate arguments with precise error reporting:
    /// ```swift
    /// let params = ToolParameters(parameters)
    /// let path = try params.require("path", as: String.self)
    /// let limit = params.optional("limit", as: Int.self) ?? 10
    /// ```
    func execute(parameters: [String: Any]) async throws -> ToolResult

    /// Generates a compact summary of the tool execution for context compression.
    ///
    /// This summary replaces the full tool output in the chat history to save tokens.
    /// - Parameters:
    ///   - parameters: The parameters used for execution.
    ///   - result: The result of execution.
    /// - Returns: A compact summary string, e.g. "[read_file(path=...)] → 45 lines".
    func summarize(parameters: [String: Any], result: ToolResult) -> String

    /// Type-erases the tool to ``AnyTool``.
    func toAnyTool() -> AnyTool
}

// MARK: - Default Implementation

public extension Tool {
    /// Default: no usage example provided.
    var usageExample: String? {
        nil
    }

    /// Default summarize implementation that generates a compact description of inputs and outputs.
    func summarize(parameters: [String: Any], result: ToolResult) -> String {
        // Extract key parameter values (max 3, truncated)
        let paramSummary = parameters.keys.sorted().prefix(3).compactMap { key -> String? in
            guard let value = parameters[key] else { return nil }
            let valueStr = String(describing: value).prefix(20)
            return "\(key)=\(valueStr)"
        }.joined(separator: ", ")

        // Truncate result
        let resultSummary: String
        if result.success {
            let lines = result.output.components(separatedBy: .newlines).count
            if lines > 1 {
                resultSummary = "\(lines) lines"
            } else {
                resultSummary = String(result.output.prefix(50))
            }
        } else {
            resultSummary = "error: \(result.error?.prefix(30) ?? "unknown")"
        }

        return "[\(id)(\(paramSummary))] → \(resultSummary)"
    }

    /// Wraps the current tool in an ``AnyTool`` container.
    func toAnyTool() -> AnyTool {
        AnyTool(self)
    }
}

public extension Tool {
    /// Standard prompt representation for tools.
    var promptString: String {
        promptString(provenance: nil)
    }

    /// Formatted content for inclusion in LLM prompt with optional provenance (e.g. workspace name).
    func promptString(provenance: String?) -> String {
        let label = provenance.map { " [\($0)]" } ?? ""
        return "- `\(id)`\(label): \(description)"
    }
}

// MARK: - Array Extension (for concrete types and protocols)

/// Formats a list of tools into a structured string for inclusion in system instructions.
public func formatToolsForPrompt(_ tools: [AnyTool]) async -> String {
    guard !tools.isEmpty else { return "" }

    var toolSpecs: [String] = []

    for tool in tools {
        guard await tool.canExecute() else { continue }
        toolSpecs.append(tool.promptString(provenance: tool.provenance))
    }

    guard !toolSpecs.isEmpty else { return "" }

    return """
    Available tools:
    \(toolSpecs.joined(separator: "\n"))

    Rules:
    - Use tools only for missing context.
    - Create memories frequently via `create_memory`.
    - Path Resolution: If a tool provenance indicates a specific workspace \
    (e.g. `[Workspace: project-x]`), all file paths passed to it MUST be relative \
    to that workspace root.
    - System Tools: Tools labeled `[System]` have global scope or session-specific sandbox scope.
    - Summarize the result if it is excessively long.
    - If a tool call fails, you can attempt to recover by correcting the parameters and trying again.
    - Be specific.
    """
}

/// Persistent configuration for a specific tool within a chat session.
public struct ToolConfiguration: Codable, Identifiable, Sendable {
    /// The unique identifier of the tool.
    public let id: String

    /// Whether the tool is active and can be called by the LLM in this session.
    public var isEnabled: Bool

    public init(toolId: String, isEnabled: Bool = true) {
        id = toolId
        self.isEnabled = isEnabled
    }
}

// MARK: - Type-Erased Tool

public protocol ToolReferenceProviding {
    var toolReference: ToolReference { get }
}

/// A type-erased wrapper around any `Tool` conformance.
///
/// Use `AnyTool` when you need to store tools in a concrete type context
/// (e.g., arrays, dictionaries) without `any Tool` existential boxing.
///
/// ```swift
/// let tool: AnyTool = AnyTool(myReadFileTool)
/// let result = try await tool.execute(parameters: ["path": "/tmp/file.txt"])
/// ```
public struct AnyTool: Tool, Sendable {
    private let wrapped: any Tool

    /// Optional metadata about where the tool originated (e.g. workspace name).
    public var provenance: String?

    public init(_ tool: any Tool, provenance: String? = nil) {
        wrapped = tool
        self.provenance = provenance
    }

    public var id: String {
        wrapped.id
    }

    public var name: String {
        wrapped.name
    }

    public var description: String {
        wrapped.description
    }

    public var requiresPermission: Bool {
        wrapped.requiresPermission
    }

    public var usageExample: String? {
        wrapped.usageExample
    }

    public var parametersSchema: [String: AnyCodable] {
        wrapped.parametersSchema
    }

    public func canExecute() async -> Bool {
        await wrapped.canExecute()
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        try await wrapped.execute(parameters: parameters)
    }

    public func summarize(parameters: [String: Any], result: ToolResult) -> String {
        wrapped.summarize(parameters: parameters, result: result)
    }
    /// Returns the ``ToolReference`` for this tool, used for internal routing and event emission.
    public var toolReference: ToolReference {
        if let provider = wrapped as? ToolReferenceProviding {
            return provider.toolReference
        }
        return .known(id: id)
    }
}
