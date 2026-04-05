import Foundation
import Logging
import MonadShared

// MARK: - ToolTimelineContext

/// Manages the lifecycle of active tool contexts.
///
/// Only one context can be active at a time. When a new context is activated,
/// any existing non-persistent context is first deactivated.
public actor ToolTimelineContext {
    private let logger = Logger.module(named: "tools")

    /// Currently active context (only one at a time)
    public private(set) var activeContext: (any ToolContext)?

    /// IDs of tools belonging to the active context
    private var contextToolIds: Set<String> = []

    /// The ID of the gateway tool that activated the current context
    private var activeGatewayToolId: String?

    public init() {}

    /// Activate a new context (deactivates any existing non-persistent context)
    public func activate(_ context: any ToolContext, gatewayToolId: String? = nil) async {
        // Deactivate existing context first (only if it's not persistent)
        if let existing = activeContext, !existing.isPersistent {
            logger.info("Deactivating context: \(type(of: existing).contextId)")
            await existing.deactivate()
        }

        activeContext = context
        activeGatewayToolId = gatewayToolId
        let tools = await context.contextTools
        contextToolIds = Set(tools.map { $0.id })

        logger.info("Activated context: \(type(of: context).contextId)")
        await context.activate()
    }

    /// Deactivate current context (only if not persistent)
    public func deactivate() async {
        guard let context = activeContext else { return }

        // Persistent contexts don't get deactivated by this method
        if context.isPersistent {
            logger.info("Context \(type(of: context).contextId) is persistent, not deactivating")
            return
        }

        logger.info("Deactivating context: \(type(of: context).contextId)")
        await context.deactivate()

        activeContext = nil
        activeGatewayToolId = nil
        contextToolIds = []
    }

    /// Force deactivate context (even if persistent)
    public func forceDeactivate() async {
        guard let context = activeContext else { return }

        logger.info("Force deactivating context: \(type(of: context).contextId)")
        await context.deactivate()

        activeContext = nil
        activeGatewayToolId = nil
        contextToolIds = []
    }

    /// Check if a tool belongs to the active context
    public func isContextTool(_ toolId: String) -> Bool {
        contextToolIds.contains(toolId)
    }

    /// Check if a tool is the gateway for the currently active context
    public func isActiveContextGateway(_ toolId: String) -> Bool {
        activeGatewayToolId == toolId
    }

    /// Get context tools if a context is active
    public func getContextTools() async -> [AnyTool] {
        await activeContext?.contextTools ?? []
    }

    /// Check if any context is active
    public var hasActiveContext: Bool {
        activeContext != nil
    }

    /// Get the ID of the active context, if any
    public var activeContextId: String? {
        activeContext.map { type(of: $0).contextId }
    }

    /// Check if active context is persistent
    public var isActiveContextPersistent: Bool {
        activeContext?.isPersistent ?? false
    }
}
