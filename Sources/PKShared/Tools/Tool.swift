import Foundation
import struct JSONSchema.Schema

/// Where a tool originated, used to scope its availability and to label it in prompts.
public enum ToolProvenance: Sendable, Equatable, Hashable, Codable {
    /// A system-wide tool available regardless of workspace/terminal context.
    case global
    /// A tool contributed by a specific workspace; paths passed to it are relative to that workspace root.
    case workspace(id: UUID, name: String)
    /// A tool contributed by a specific terminal session.
    case terminal(id: UUID, name: String)
    /// A tool with an arbitrary caller-supplied provenance label.
    case named(String)

    public var promptLabel: String? {
        switch self {
        case .global:
            nil
        case let .workspace(_, name):
            "Workspace: \(name)"
        case let .terminal(_, name):
            "Terminal: \(name)"
        case let .named(name):
            name
        }
    }

    public var displayName: String {
        promptLabel ?? "System"
    }
}

public protocol ToolProviding: Sendable {
    var toolProvenance: ToolProvenance { get }
    func provideTools() async -> [AnyTool]
}

public extension ToolProviding {
    func resolvedTools() async -> [AnyTool] {
        await provideTools().map { tool in
            var resolved = tool
            if resolved.provenance == .global {
                resolved.provenance = toolProvenance
            }
            return resolved
        }
    }
}

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

    /// Whether the tool is currently available for execution.
    func canExecute() async -> Bool

    /// JSON Schema describing the parameters this tool accepts.
    ///
    /// Typed as `JSONSchema.Schema` — the same surface used by `LLMToolDefinition.parameters`
    /// and `SidecarDirective.schema` — so a tool's schema flows to the LLM without an
    /// encode/decode round-trip. Use ``ToolParameterSchema`` to build this in a type-safe way:
    /// ```swift
    /// var parametersSchema: Schema {
    ///     ToolParameterSchema.object {
    ///         JSONProperty(key: "path") { JSONString().description("…") }.required()
    ///     }.schemaDefinition
    /// }
    /// ```
    var parametersSchema: Schema { get }

    /// Executes the tool logic with the parameters provided by the LLM.
    ///
    /// - Parameter parameters: Dictionary of argument names to `AnyCodable` values (Sendable).
    /// - Returns: A ``ToolResult`` containing the output or error message.
    ///
    /// Use ``ToolParameters`` to decode and validate arguments with precise error reporting:
    /// ```swift
    /// let params = ToolParameters(parameters)
    /// let path = try params.require("path", as: String.self)
    /// let limit = params.optional("limit", as: Int.self) ?? 10
    /// ```
    func execute(parameters: [String: AnyCodable]) async throws -> ToolResult

    /// Generates a compact summary of the tool execution for context compression.
    ///
    /// This summary replaces the full tool output in the chat history to save tokens.
    /// - Parameters:
    ///   - parameters: The parameters used for execution.
    ///   - result: The result of execution.
    /// - Returns: A compact summary string, e.g. "[read_file(path=...)] → 45 lines".
    func summarize(parameters: [String: AnyCodable], result: ToolResult) -> String

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
    func summarize(parameters: [String: AnyCodable], result: ToolResult) -> String {
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
        promptString(provenance: .global)
    }

    /// Formatted content for inclusion in LLM prompt with optional provenance (e.g. workspace name).
    func promptString(provenance: ToolProvenance) -> String {
        let label = provenance.promptLabel.map { " [\($0)]" } ?? ""
        return "- `\(id)`\(label): \(description)"
    }
}

// MARK: - Array Extension (for concrete types and protocols)

public extension [AnyTool] {
    /// Formats this list of tools into a structured string for inclusion in system instructions.
    func formattedForPrompt() async -> String {
        guard !isEmpty else { return "" }

        var toolSpecs: [String] = []

        for tool in self {
            guard await tool.canExecute() else { continue }
            toolSpecs.append(tool.promptString(provenance: tool.provenance))
        }

        guard !toolSpecs.isEmpty else { return "" }

        return """
        Available tools:
        \(toolSpecs.joined(separator: "\n"))

        Rules:
        - Use tools only for missing context.
        - Path Resolution: If a tool is tagged with a workspace provenance \
        (e.g. `[Workspace: <name>]` or `[Terminal: <name>]`), all file paths passed to it MUST be relative \
        to that workspace root.
        - Summarize the result if it is excessively long.
        - If a tool call fails, the error response tells you what went wrong and how to \
        fix it (often with a worked example) — correct the arguments and try again.
        - Be specific.
        """
    }
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

    /// Metadata about where the tool originated.
    public var provenance: ToolProvenance

    public init(_ tool: any Tool, provenance: ToolProvenance = .global) {
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

    public var parametersSchema: Schema {
        wrapped.parametersSchema
    }

    public func canExecute() async -> Bool {
        await wrapped.canExecute()
    }

    public func execute(parameters: [String: AnyCodable]) async throws -> ToolResult {
        try await wrapped.execute(parameters: parameters)
    }

    public func summarize(parameters: [String: AnyCodable], result: ToolResult) -> String {
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
