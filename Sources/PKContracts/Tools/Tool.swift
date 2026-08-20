import Foundation
import struct JSONSchema.Schema

/// Where a tool originated, used to scope its availability and to label it in prompts.
public enum ToolOrigin: Sendable, Equatable, Hashable, Codable {
    /// A system-wide tool available regardless of workspace/terminal context.
    case global
    /// A tool contributed by a specific workspace; paths passed to it are relative to that workspace root.
    case workspace(id: UUID, name: String)
    /// A tool contributed by a specific terminal session.
    case terminal(id: UUID, name: String)
    /// A tool with an arbitrary caller-supplied origin label.
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

public protocol ToolSource: Sendable {
    var toolOrigin: ToolOrigin { get }
    func tools() async -> [AnyTool]
}

public extension ToolSource {
    func resolvedTools() async -> [AnyTool] {
        await tools().map { tool in
            tool.origin == .global ? tool.withOrigin(toolOrigin) : tool
        }
    }
}

/// The side-effect class of a tool, used by the timeout enforcer to decide whether
/// abandonment after a wall-clock timeout is safe.
///
/// `ToolTimeoutEnforcer` cancels uncooperative tool tasks best-effort after timeout
/// and returns promptly rather than blocking until the tool body finishes. For tools
/// that mutate no external state this is honest — the operation effectively stopped.
/// For tools that mutate in-process or external state, cancellation is not
/// termination: the tool may still complete its side effects after the caller has
/// been informed of the timeout, and retrying can duplicate writes, commands,
/// payments, file changes, or remote operations. The enforcer uses this value to
/// report a distinct terminal state (`ToolError.timedOutButMayStillBeRunning`)
/// rather than a clean timeout when abandonment is not provably safe.
public enum ToolSideEffects: Sendable, Equatable {
    /// No external state is mutated; safe to abandon after timeout.
    case none
    /// In-process state may be mutated (files, memory, in-process records).
    case mutating
    /// External processes or remote services may be mutated; termination
    /// requires an out-of-band kill path the runtime does not own.
    case externalProcess
}

/// A tool that the LLM can call to interact with workspaces, data, or computations.
///
/// Implement this protocol to add new capabilities to the AI assistant. Tools are automatically
/// registered and exposed to the LLM during context construction.
public protocol Tool: Sendable, PromptFormattable {
    /// The callable name the LLM uses to invoke this tool (e.g., `"read_file"`).
    ///
    /// This value becomes the `name` field of ``LLMToolDefinition`` on the wire — it is the
    /// function name the model emits in a tool call, not a display label. Use ``name`` for
    /// human-readable display.
    var callName: String { get }

    /// Immutable identity used for internal routing and event emission.
    ///
    /// Captured once at ``AnyTool`` erasure and never re-derived. Tools that need a
    /// non-default identity (e.g. a `.custom` reference) override this; the default derives
    /// a `.known(id:)`-style identity from ``callName``.
    var identity: ToolReference { get }

    /// Human-readable display name for the tool.
    var name: String { get }

    /// Clear, concise description of what the tool does and when the LLM should use it.
    var description: String { get }

    /// Whether the tool requires explicit user permission before execution.
    /// If true, the system will prompt the user to approve the tool call.
    var requiresPermission: Bool { get }

    /// The side-effect class of this tool, used by the timeout enforcer to decide
    /// whether abandonment after a wall-clock timeout is safe. Defaults to
    /// `.mutating` — the conservative assumption for tools that do not declare
    /// themselves side-effect-free. A tool that mutates no external state should
    /// override this with `.none` to preserve the fast-abandon clean timeout;
    /// a tool that drives external processes or remote services should override
    /// it with `.externalProcess`.
    var sideEffects: ToolSideEffects { get }

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
    /// Implementations run in ordinary Swift tasks and must remain nonblocking so cancellation
    /// and wall-clock timeout handling can make progress. Suspend for waits through asynchronous
    /// APIs; do not directly use `Thread.sleep`, semaphore waits, synchronous networking, or
    /// blocking subprocess waits. Bridge unavoidable legacy blocking work to an
    /// implementation-owned queue or thread, or wrap it in an asynchronous API whose lifecycle
    /// the implementation controls.
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
    /// Default identity derived from ``callName``.
    var identity: ToolReference {
        .known(id: callName)
    }

    /// Default: no usage example provided.
    var usageExample: String? {
        nil
    }

    /// Default side-effect class: conservative assumption that the tool mutates
    /// in-process state, so the timeout enforcer reports
    /// `timedOutButMayStillBeRunning` rather than a clean timeout. Tools that are
    /// genuinely side-effect-free should override this with `.none`.
    var sideEffects: ToolSideEffects {
        .mutating
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

        return "[\(callName)(\(paramSummary))] → \(resultSummary)"
    }

    /// Wraps the current tool in an ``AnyTool`` container.
    func toAnyTool() -> AnyTool {
        AnyTool(self)
    }
}

public extension Tool {
    /// Standard prompt representation for tools.
    var promptString: String {
        promptString(origin: .global)
    }

    /// Formatted content for inclusion in LLM prompt with optional origin (e.g. workspace name).
    func promptString(origin: ToolOrigin) -> String {
        let label = origin.promptLabel.map { " [\($0)]" } ?? ""
        return "- `\(callName)`\(label): \(description)"
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
            toolSpecs.append(tool.promptString(origin: tool.origin))
        }

        guard !toolSpecs.isEmpty else { return "" }

        return """
        Available tools:
        \(toolSpecs.joined(separator: "\n"))

        Rules:
        - Use tools only for missing context.
        - Path Resolution: If a tool is tagged with a workspace origin \
        (e.g. `[Workspace: <name>]` or `[Terminal: <name>]`), all file paths passed to it MUST be relative \
        to that workspace root.
        - Summarize the result if it is excessively long.
        - If a tool call fails, the error response tells you what went wrong and how to \
        fix it (often with a worked example) — correct the arguments and try again.
        - Be specific.
        """
    }
}

// MARK: - Type-Erased Tool

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

    /// Immutable metadata about where the tool originated.
    public let origin: ToolOrigin

    /// Immutable tool identity captured at erasure time.
    public let identity: ToolReference

    public init(_ tool: any Tool, origin: ToolOrigin = .global) {
        wrapped = tool
        self.origin = origin
        identity = tool.identity
    }

    /// Returns a copy of this tool with the origin replaced, preserving identity.
    public func withOrigin(_ newOrigin: ToolOrigin) -> AnyTool {
        AnyTool(wrapped, origin: newOrigin)
    }

    /// Overrides the protocol default (which would rewrap in a fresh `AnyTool` and reset
    /// `origin` to `.global`) so re-erasing an already-erased tool is a no-op.
    public func toAnyTool() -> AnyTool {
        self
    }

    public var callName: String {
        wrapped.callName
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

    public var sideEffects: ToolSideEffects {
        wrapped.sideEffects
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

    /// Returns the ``ToolReference`` captured at erasure time.
    public var toolReference: ToolReference {
        identity
    }
}
