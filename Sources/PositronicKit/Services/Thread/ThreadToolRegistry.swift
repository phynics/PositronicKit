import Foundation
import Logging
import PKContracts
import PKUtilities

/// Thread-specific tool settings
package actor ThreadToolRegistry {
    package private(set) var enabledTools: Set<String> = []

    /// available tools in the system
    public private(set) var availableTools: [AnyTool]

    /// Registered workspaces providing tools
    private var workspaces: [UUID: any Workspace] = [:]

    /// Cached workspace tools: toolId -> (wrapper, origin)
    private var workspaceTools: [String: (tool: WorkspaceToolWrapper, origin: ToolOrigin)] = [:]

    /// Cached known-tool overrides from workspaces: toolId -> Set of origin tags.
    private var knownToolOrigin: [String: Set<ToolOrigin>] = [:]

    /// Explicitly registered tool providers (global or workspace-bound). Assembled alongside
    /// workspace-derived tools so the runtime has a single canonical source for turn tools.
    private var toolProviders: [UUID: any ToolSource] = [:]

    /// Cached provider tools: toolId -> tool.
    private var providerTools: [String: AnyTool] = [:]

    private let logger = Logger.module(named: "thread-tool-manager")

    public init(availableTools: [AnyTool]) {
        self.availableTools = availableTools
        // Enable all tools by default
        enabledTools = Set(availableTools.map { $0.callName })
    }

    /// Update available tools
    public func updateAvailableTools(_ tools: [AnyTool]) {
        availableTools = tools
        // Keep enabledTools set in sync with available tools (don't remove enabled status if tool still exists)
        let newIds = Set(tools.map { $0.callName })
        enabledTools = enabledTools.intersection(newIds)
        // Auto-enable new tools? Let's say yes for now to avoid breaking changes.
        for id in newIds where !enabledTools.contains(id) {
            self.enabledTools.insert(id)
        }
    }

    /// Register a workspace and load its tools
    public func registerWorkspace(_ workspace: any Workspace) async {
        workspaces[workspace.id] = workspace
        await refreshWorkspaceTools()
    }

    /// Unregister a workspace
    public func unregisterWorkspace(_ id: UUID) async {
        workspaces.removeValue(forKey: id)
        await refreshWorkspaceTools()
    }

    /// Register an explicit tool provider. Provider tools are assembled into the turn tool set
    /// alongside workspace-derived tools.
    public func registerToolProvider(_ provider: any ToolSource, id: UUID) async {
        toolProviders[id] = provider
        await refreshProviderTools()
    }

    /// Unregister a tool provider.
    public func unregisterToolProvider(_ id: UUID) async {
        toolProviders.removeValue(forKey: id)
        await refreshProviderTools()
    }

    /// Refresh tools from all registered workspaces
    private func refreshWorkspaceTools() async {
        var newTools: [String: (tool: WorkspaceToolWrapper, origin: ToolOrigin)] = [:]
        var newKnownOrigin: [String: Set<ToolOrigin>] = [:]

        for workspace in workspaces.values {
            let originTag = ToolOrigin.workspace(
                id: workspace.id,
                name: workspace.reference.uri.description
            )
            do {
                let refs = try await workspace.listTools()
                for ref in refs {
                    switch ref {
                    case let .known(toolId):
                        // Tag the system tool with this workspace's origin
                        if availableTools.contains(where: { $0.callName == toolId }) {
                            newKnownOrigin[toolId, default: []].insert(originTag)
                        } else {
                            logger.warning(
                                "Workspace declared .known tool '\(toolId)' but it is not a registered system tool"
                            )
                        }
                    case let .custom(def):
                        let wrapper = WorkspaceToolWrapper(workspace: workspace, definition: def)
                        newTools[wrapper.callName] = (tool: wrapper, origin: originTag)
                    }
                }
            } catch {
                logger.error("Failed to list tools for workspace \(workspace.id): \(error)")
            }
        }

        workspaceTools = newTools
        knownToolOrigin = newKnownOrigin
    }

    /// Refresh tools from all registered providers. Provider tools that declare `.global`
    /// origin are stamped with the provider's `toolOrigin` via `resolvedTools()`.
    private func refreshProviderTools() async {
        var newProviderTools: [String: AnyTool] = [:]
        for provider in toolProviders.values {
            let tools = await provider.resolvedTools()
            for tool in tools {
                newProviderTools[tool.callName] = tool
            }
        }
        providerTools = newProviderTools
    }

    /// Stamps `tool` with the resolved origin from the set of workspaces that declared it
    /// as a `.known` tool. When multiple workspaces share a known tool, origin collapses to
    /// a single representative — the lexicographically smallest `displayName` — so the prompt
    /// label is deterministic across refreshes rather than depending on `Set` iteration order.
    /// A tool can only carry one origin tag; the sort makes that one choice stable.
    private func toolWithResolvedOrigin(_ tool: AnyTool) -> AnyTool {
        guard let originSet = knownToolOrigin[tool.callName], !originSet.isEmpty else {
            return tool
        }
        let resolvedOrigin = originSet.sorted(by: { $0.displayName < $1.displayName }).first ?? .global
        return tool.withOrigin(resolvedOrigin)
    }

    /// Sorts the aggregated tool list into a deterministic order before it is serialized into
    /// LLM requests or recorded in prompt history. The ordering key is `(name, origin.displayName)`;
    /// origin breaks ties when the same tool name is offered by different sources.
    private func sortToolsForOutput(_ tools: [AnyTool]) -> [AnyTool] {
        tools.sorted {
            if $0.name != $1.name {
                return $0.name < $1.name
            }
            return $0.origin.displayName < $1.origin.displayName
        }
    }

    /// True iff `origin` tags a tool as belonging to `workspaceId` (i.e. it is the
    /// `.workspace(id:name:)` case with a matching id). `.global`/`.named` never match.
    private static func originBelongsTo(_ origin: ToolOrigin, _ workspaceId: UUID) -> Bool {
        if case let .workspace(id, _) = origin { return id == workspaceId }
        return false
    }

    /// Get tools that are currently enabled
    public func getEnabledTools() async -> [AnyTool] {
        var tools = availableTools.filter { enabledTools.contains($0.callName) }

        // Apply workspace origin to .known system tools
        tools = tools.map { toolWithResolvedOrigin($0) }

        // Include workspace custom tools with origin
        tools.append(contentsOf: workspaceTools.values.map { entry in
            AnyTool(entry.tool, origin: entry.origin)
        })

        // Include explicitly registered provider tools
        tools.append(contentsOf: providerTools.values)

        return sortToolsForOutput(tools)
    }

    public func getAvailableTools() -> [AnyTool] {
        var tools = availableTools

        // Apply origin to .known system tools
        tools = tools.map { toolWithResolvedOrigin($0) }

        // Append workspace custom tools with origin
        tools.append(contentsOf: workspaceTools.values.map { entry in
            AnyTool(entry.tool, origin: entry.origin)
        })

        // Append explicitly registered provider tools
        tools.append(contentsOf: providerTools.values)
        return sortToolsForOutput(tools)
    }

    /// Returns call names that are registered but currently disabled.
    ///
    /// Request-scoped tools are not part of this registry. Keeping this distinction lets the
    /// router admit genuinely dynamic tools while still making a disabled registered name
    /// authoritative when a dynamic tool collides with it.
    func disabledToolIDs() -> Set<String> {
        Set(availableTools.map(\.callName)).subtracting(enabledTools)
    }

    /// Returns the tools currently exposed by a specific workspace: its custom workspace
    /// tools plus any `.known` system tools it has declared, each carrying its resolved
    /// origin. Provider/global tools are excluded (they are not workspace-bound).
    ///
    /// This is the read-side counterpart to the per-workspace grouping `ToolRouter.resolveWorkspace`
    /// uses to route calls — the grouping data already exists internally; this exposes it as a
    /// query so a consumer need not fetch the flat list and filter by `origin` client-side.
    public func tools(inWorkspace workspaceId: UUID) -> [AnyTool] {
        var tools: [AnyTool] = []

        // Custom workspace tools whose origin matches this workspace.
        for entry in workspaceTools.values where Self.originBelongsTo(entry.origin, workspaceId) {
            tools.append(AnyTool(entry.tool, origin: entry.origin))
        }

        // `.known` system tools this workspace has declared (tagged via knownToolOrigin).
        for (toolId, originSet) in knownToolOrigin {
            if originSet.contains(where: { Self.originBelongsTo($0, workspaceId) }),
               let tool = availableTools.first(where: { $0.callName == toolId })
            {
                tools.append(toolWithResolvedOrigin(tool))
            }
        }

        return sortToolsForOutput(tools)
    }

    /// Returns all workspace-exposed tools grouped by workspace id. Provider/global tools
    /// (not workspace-bound) are excluded; only registered workspaces appear as keys.
    public func toolsGroupedByWorkspace() -> [UUID: [AnyTool]] {
        var grouped: [UUID: [AnyTool]] = [:]
        for workspaceId in workspaces.keys {
            grouped[workspaceId] = tools(inWorkspace: workspaceId)
        }
        return grouped
    }

    /// Toggle tool enabled state
    public func toggleTool(_ toolId: String) {
        if enabledTools.contains(toolId) {
            enabledTools.remove(toolId)
        } else {
            enabledTools.insert(toolId)
        }
    }

    /// Enable a tool explicitly
    public func enableTool(id: String) {
        // Only enable if it is available (checking system tools)
        // Workspace tools are always enabled if present for now?
        if availableTools.contains(where: { $0.callName == id }) {
            enabledTools.insert(id)
        }
    }

    /// Disable a tool explicitly
    public func disableTool(id: String) {
        enabledTools.remove(id)
    }

    /// Get tool by ID (checks system, context, and workspace tools)
    public func getTool(id: String) async -> AnyTool? {
        // First check regular system tools
        if let tool = availableTools.first(where: { $0.callName == id }) {
            return toolWithResolvedOrigin(tool)
        }

        // Then check workspace tools
        if let entry = workspaceTools[id] {
            return AnyTool(entry.tool, origin: entry.origin)
        }

        // Then check explicitly registered provider tools
        if let tool = providerTools[id] {
            return tool
        }

        return nil
    }
}
