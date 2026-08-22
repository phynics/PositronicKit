import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import PKContracts

/// The immutable workspace/tool authority captured for one admitted managed Turn.
///
/// This snapshot is deliberately independent of the live workspace catalog. Attachment or tool
/// changes made after admission therefore affect the next Turn, never a Turn already in flight.
struct WorkspaceToolCatalog: Sendable {
    struct Entry: Sendable {
        let workspace: WorkspaceReference
        let label: String
        let isPrimary: Bool
        let tools: [AnyTool]
        let directTools: [AnyTool]

        init(
            workspace: WorkspaceReference,
            label: String,
            isPrimary: Bool,
            tools: [AnyTool],
            directTools: [AnyTool] = []
        ) {
            self.workspace = workspace
            self.label = label
            self.isPrimary = isPrimary
            self.tools = tools
            self.directTools = directTools
        }

        var candidates: [WorkspaceToolCandidate] {
            tools.map { tool in
                WorkspaceToolCandidate(
                    workspaceID: workspace.id,
                    label: label,
                    toolID: tool.callName,
                    toolName: tool.name,
                    description: tool.description,
                    parametersSchema: tool.parametersSchema.asDictionary,
                    isPrimary: isPrimary
                )
            }
        }
    }

    let entries: [Entry]

    var isEmpty: Bool { entries.allSatisfy { $0.tools.isEmpty } }

    /// Generic Agent-primary file tools are exposed directly to the model. Other workspace tools
    /// remain behind `call_tool` so their workspace routing stays explicit.
    var directTools: [AnyTool] {
        entries.first(where: \.isPrimary)?.directTools ?? []
    }

    var callTool: AnyTool {
        AnyTool(WorkspaceCallTool())
    }
}

/// Marker tool exposed to the model for workspace-only dispatch.
///
/// The router consumes this marker before normal tool execution. Its implementation is a guard
/// against accidental direct execution if a future call path forgets to use the dispatcher.
private struct WorkspaceCallTool: Tool, Sendable {
    let callName = "call_tool"
    let name = "Workspace Tool"
    let description = "Call a tool in an authorized workspace. Omit 'at' only when exactly one workspace matches."
    let requiresPermission = false
    let sideEffects: ToolSideEffects = .mutating
    let usageExample: String? = "call_tool(tool: \"read_file\", at: \"<workspace-id>\", arguments: {\"path\": \"README.md\"})"

    var parametersSchema: Schema {
        Schema([
            "type": .string("object"),
            "properties": .dictionary([
                "tool": .dictionary(["type": .string("string")]),
                "at": .dictionary(["type": .string("string")]),
                "arguments": .dictionary([
                    "type": .string("object"),
                    "additionalProperties": .boolean(true),
                ]),
            ]),
            "required": .array([.string("tool")]),
            "additionalProperties": .boolean(false),
        ])
    }

    func canExecute() async -> Bool { true }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .failure("Workspace call_tool must be routed by the Turn runtime.")
    }
}

extension ThreadManager {
    private static let reservedAgentWorkspaceToolNames: Set<String> = [
        "read_file", "list_files", "search_files", "write_file", "append_file", "edit_file", "delete_file",
    ]

    /// Captures the authorized workspace tools used by a managed Turn.
    ///
    /// The caller invokes this from the same admission authority lane used for Agent and Thread
    /// mutations. Workspace references and tool wrappers are copied into the returned value before
    /// the durable Turn admission is committed.
    func captureWorkspaceToolCatalog(
        for threadID: UUID,
        primaryWorkspaceID: UUID?
    ) async throws -> WorkspaceToolCatalog {
        let query = try await getWorkspaces(for: threadID)
        var references: [(WorkspaceReference, Bool)] = []
        if let primaryWorkspaceID,
           let primary = try await workspaceStore.fetchWorkspace(id: primaryWorkspaceID, includeTools: true)
        {
            references.append((primary, true))
        }
        if let primary = query.primary,
           !references.contains(where: { $0.0.id == primary.id })
        {
            references.append((primary, false))
        }
        for reference in query.attached where !references.contains(where: { $0.0.id == reference.id }) {
            references.append((reference, false))
        }

        guard !references.isEmpty else { return WorkspaceToolCatalog(entries: []) }
        let registry = toolManagers[threadID]
        var entries: [WorkspaceToolCatalog.Entry] = []

        for (reference, isPrimary) in references {
            var tools: [AnyTool] = []
            if !isPrimary, let registry {
                tools = await registry.tools(inWorkspace: reference.id)
            }

            // The primary Agent workspace is not an ordinary Thread binding, so hydrate its
            // wrappers directly. This also fills any custom definitions unavailable in the
            // Thread registry while preserving known system tools where applicable.
            var fileProvider: (any WorkspaceFileProvider)?
            let liveWorkspace = try? await workspaceResolver.workspace(id: reference.id)
            fileProvider = liveWorkspace as? any WorkspaceFileProvider
            if isPrimary, fileProvider == nil, reference.rootPath != nil {
                fileProvider = try? LocalAgentWorkspaceProvider(reference: reference)
            }
            if let toolProvider = liveWorkspace as? any WorkspaceToolProvider
            {
                let listed = (try? await toolProvider.listTools()) ?? []
                let available: [AnyTool]
                if let registry {
                    available = await registry.getAvailableTools()
                } else {
                    available = []
                }
                for toolReference in listed {
                    switch toolReference {
                    case let .known(id):
                        if let known = available.first(where: { $0.callName == id && $0.origin == .global }) {
                            tools.append(known.withOrigin(.workspace(id: reference.id, name: reference.uri.description)))
                        }
                    case let .custom(definition):
                        tools.append(AnyTool(
                            WorkspaceToolWrapper(workspace: toolProvider, definition: definition),
                            origin: .workspace(id: reference.id, name: reference.uri.description)
                        ))
                    }
                }
            }

            // Agent primary workspaces always receive the guarded generic filesystem surface.
            // These names are reserved so a workspace-provided definition cannot silently replace
            // a path-jailed built-in or bypass SOUL.md approval.
            var genericTools: [AnyTool] = []
            if isPrimary, let fileProvider {
                let origin = ToolOrigin.workspace(id: reference.id, name: reference.uri.description)
                genericTools = AgentWorkspaceFileTool.Operation.all.map { operation in
                    AnyTool(
                        AgentWorkspaceFileTool(operation: operation, provider: fileProvider),
                        origin: origin
                    )
                }
            }

            var seen = Set<String>()
            tools = (genericTools + tools).filter { tool in
                if isPrimary, Self.reservedAgentWorkspaceToolNames.contains(tool.callName),
                   genericTools.isEmpty { return false }
                return seen.insert(tool.callName).inserted
            }
            tools.sort { ($0.callName, $0.name) < ($1.callName, $1.name) }
            entries.append(.init(
                workspace: reference,
                label: reference.uri.description,
                isPrimary: isPrimary,
                tools: tools,
                directTools: genericTools
            ))
        }

        return WorkspaceToolCatalog(entries: entries.sorted {
            ($0.isPrimary ? 0 : 1, $0.label, $0.workspace.id.uuidString)
                < ($1.isPrimary ? 0 : 1, $1.label, $1.workspace.id.uuidString)
        })
    }
}
