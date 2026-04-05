import Foundation
import Logging
import MonadShared

// MARK: - ToolContext

public protocol ToolContext: AnyObject, Sendable {
    /// Unique identifier for this context type
    static var contextId: String { get }

    /// Human-readable name for the context
    static var displayName: String { get }

    /// Description of what this context provides
    static var contextDescription: String { get }

    /// Whether this context persists when other (non-context) tools are called.
    /// Default: false (auto-exits on non-context tool calls)
    var isPersistent: Bool { get }

    /// Tools available only within this context
    var contextTools: [AnyTool] { get async }

    /// Called when context is activated
    func activate() async

    /// Called when context is deactivated
    func deactivate() async

    /// Format current state for inclusion in tool output
    func formatState() async -> String

    /// Welcome message shown when context is activated
    func welcomeMessage() async -> String
}

// MARK: - Default Implementations

public extension ToolContext {
    /// Default: non-persistent (auto-exits on non-context tool calls)
    var isPersistent: Bool {
        false
    }

    func activate() async {
        // Default: no-op
    }

    func deactivate() async {
        // Default: no-op
    }

    func welcomeMessage() async -> String {
        let tools = await contextTools
        let toolList = tools.map { "- `\($0.id)`: \($0.description)" }.joined(
            separator: "\n"
        )

        let exitNote =
            isPersistent
                ? "This context persists across other tool calls."
                : "Calling any non-context tool will exit this context."

        return """
        \(Self.displayName) activated.

        Available commands:
        \(toolList)

        Note: \(exitNote)

        \(await formatState())
        """
    }
}
