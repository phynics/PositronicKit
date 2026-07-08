import Foundation
import Logging
import PKShared

/// Session-specific tool settings
public actor TimelineToolManager {
    public private(set) var enabledTools: Set<String> = []

    /// available tools in the system
    public private(set) var availableTools: [AnyTool]

    /// Context timeline for dynamic tool injection
    public let timelineContext: ToolTimelineContext?

    /// Registered workspaces providing tools
    private var workspaces: [UUID: any WorkspaceProtocol] = [:]

    /// Cached workspace tools: toolId -> (wrapper, provenance)
    private var workspaceTools: [String: (tool: WorkspaceToolWrapper, provenance: ToolProvenance)] = [:]

    /// Cached known-tool overrides from workspaces: toolId -> Set of provenance tags.
    private var knownToolProvenance: [String: Set<ToolProvenance>] = [:]

    /// Explicitly registered tool providers (global or workspace-bound). Assembled alongside
    /// workspace-derived tools so the runtime has a single canonical source for turn tools.
    private var toolProviders: [UUID: any ToolProviding] = [:]

    /// Cached provider tools: toolId -> tool.
    private var providerTools: [String: AnyTool] = [:]

    private let logger = Logger.module(named: "session-tool-manager")

    public init(availableTools: [AnyTool], timelineContext: ToolTimelineContext? = nil) {
        self.availableTools = availableTools
        self.timelineContext = timelineContext
        // Enable all tools by default
        enabledTools = Set(availableTools.map { $0.id })
    }

    /// Update available tools
    public func updateAvailableTools(_ tools: [AnyTool]) {
        availableTools = tools
        // Keep enabledTools set in sync with available tools (don't remove enabled status if tool still exists)
        let newIds = Set(tools.map { $0.id })
        enabledTools = enabledTools.intersection(newIds)
        // Auto-enable new tools? Let's say yes for now to avoid breaking changes.
        for id in newIds where !enabledTools.contains(id) {
            self.enabledTools.insert(id)
        }
    }

    /// Register a workspace and load its tools
    public func registerWorkspace(_ workspace: any WorkspaceProtocol) async {
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
    public func registerToolProvider(_ provider: any ToolProviding, id: UUID) async {
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
        var newTools: [String: (tool: WorkspaceToolWrapper, provenance: ToolProvenance)] = [:]
        var newKnownProvenance: [String: Set<ToolProvenance>] = [:]

        for workspace in workspaces.values {
            let provenanceTag = ToolProvenance.workspace(
                id: workspace.id,
                name: workspace.reference.uri.description
            )
            do {
                let refs = try await workspace.listTools()
                for ref in refs {
                    switch ref {
                    case let .known(toolId):
                        // Tag the system tool with this workspace's provenance
                        if availableTools.contains(where: { $0.id == toolId }) {
                            newKnownProvenance[toolId, default: []].insert(provenanceTag)
                        } else {
                            logger.warning(
                                "Workspace declared .known tool '\(toolId)' but it is not a registered system tool"
                            )
                        }
                    case let .custom(def):
                        let wrapper = WorkspaceToolWrapper(workspace: workspace, definition: def)
                        newTools[wrapper.id] = (tool: wrapper, provenance: provenanceTag)
                    }
                }
            } catch {
                logger.error("Failed to list tools for workspace \(workspace.id): \(error)")
            }
        }

        workspaceTools = newTools
        knownToolProvenance = newKnownProvenance
    }

    /// Refresh tools from all registered providers. Provider tools that declare `.global`
    /// provenance are stamped with the provider's `toolProvenance` via `resolvedTools()`.
    private func refreshProviderTools() async {
        var newProviderTools: [String: AnyTool] = [:]
        for provider in toolProviders.values {
            let tools = await provider.resolvedTools()
            for tool in tools {
                newProviderTools[tool.id] = tool
            }
        }
        providerTools = newProviderTools
    }

    /// Stamps `tool` with the resolved provenance from the set of workspaces that declared it
    /// as a `.known` tool. When multiple workspaces share a known tool, provenance collapses to
    /// a single representative — the lexicographically smallest `displayName` — so the prompt
    /// label is deterministic across refreshes rather than depending on `Set` iteration order.
    /// A tool can only carry one provenance tag; the sort makes that one choice stable.
    private func toolWithResolvedProvenance(_ tool: AnyTool) -> AnyTool {
        guard let provenanceSet = knownToolProvenance[tool.id], !provenanceSet.isEmpty else {
            return tool
        }
        var tagged = tool
        tagged.provenance = provenanceSet.sorted(by: { $0.displayName < $1.displayName }).first ?? .global
        return tagged
    }

    /// Sorts the aggregated tool list into a deterministic order before it is serialized into
    /// LLM requests or recorded in prompt history. The ordering key is `(name, provenance.displayName)`;
    /// provenance breaks ties when the same tool name is offered by different sources.
    private func sortToolsForOutput(_ tools: [AnyTool]) -> [AnyTool] {
        tools.sorted {
            if $0.name != $1.name {
                return $0.name < $1.name
            }
            return $0.provenance.displayName < $1.provenance.displayName
        }
    }

    /// Get tools that are currently enabled, including context tools if a context is active
    public func getEnabledTools() async -> [AnyTool] {
        var tools = availableTools.filter { enabledTools.contains($0.id) }

        // Apply workspace provenance to .known system tools
        tools = tools.map { toolWithResolvedProvenance($0) }

        // Include context tools if a context is active
        if let timeline = timelineContext, await timeline.hasActiveContext {
            tools.append(contentsOf: await timeline.getContextTools())
        }

        // Include workspace custom tools with provenance
        tools.append(contentsOf: workspaceTools.values.map { entry in
            var tool = AnyTool(entry.tool)
            tool.provenance = entry.provenance
            return tool
        })

        // Include explicitly registered provider tools
        tools.append(contentsOf: providerTools.values)

        return sortToolsForOutput(tools)
    }

    public func getAvailableTools() -> [AnyTool] {
        var tools = availableTools

        // Apply provenance to .known system tools
        tools = tools.map { toolWithResolvedProvenance($0) }

        // Append workspace custom tools with provenance
        tools.append(contentsOf: workspaceTools.values.map { entry in
            var tool = AnyTool(entry.tool)
            tool.provenance = entry.provenance
            return tool
        })

        // Append explicitly registered provider tools
        tools.append(contentsOf: providerTools.values)
        return sortToolsForOutput(tools)
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
        if availableTools.contains(where: { $0.id == id }) {
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
        if let tool = availableTools.first(where: { $0.id == id }) {
            return toolWithResolvedProvenance(tool)
        }

        // Then check context tools if a context is active
        if let timeline = timelineContext, await timeline.hasActiveContext {
            if let tool = await timeline.getContextTools().first(where: { $0.id == id }) {
                return tool
            }
        }

        // Then check workspace tools
        if let entry = workspaceTools[id] {
            var tool = AnyTool(entry.tool)
            tool.provenance = entry.provenance
            return tool
        }

        // Then check explicitly registered provider tools
        if let tool = providerTools[id] {
            return tool
        }

        return nil
    }
}
