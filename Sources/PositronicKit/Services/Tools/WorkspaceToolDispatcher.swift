import ErrorKit
import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import Logging
import PKContracts

/// The immutable workspace/tool authority captured for one admitted Turn.
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
    }

    let entries: [Entry]

    var isEmpty: Bool { entries.allSatisfy { $0.tools.isEmpty } }

    /// Exact call names that identify one tool in this captured snapshot. Duplicate identifiers
    /// are deliberately omitted because the provider-facing selector has no safe way to resolve
    /// them, even when a Workspace UUID is also supplied.
    var advertisedToolIDs: [String] {
        var counts: [String: Int] = [:]
        for tool in entries.flatMap(\.tools) {
            counts[tool.callName, default: 0] += 1
        }
        return counts
            .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value == 1 }
            .map(\.key)
            .sorted()
    }

    /// Generic Agent-primary file tools are exposed directly to the model. Other workspace tools
    /// remain behind `call_tool` so their workspace routing stays explicit.
    var directTools: [AnyTool] {
        entries.first(where: \.isPrimary)?.directTools ?? []
    }

    var callTool: AnyTool {
        AnyTool(WorkspaceCallTool(toolIDs: advertisedToolIDs))
    }
}

/// The workspace selected from an admitted Turn's immutable catalog.
struct WorkspaceToolRoute: Sendable {
    let workspaceID: UUID
    let tool: AnyTool
    let explicit: Bool
    let isPrimary: Bool
    let location: WorkspaceReference.WorkspaceLocation

    var routing: WorkspaceToolRouting {
        explicit ? .explicit : .implicit
    }
}

/// A validated Workspace dispatch whose intent can be persisted before execution.
struct WorkspaceToolDispatch: Sendable {
    let route: WorkspaceToolRoute
    let arguments: [String: AnyCodable]
}

/// Owns captured Workspace selection, execution disposition, authority revalidation, and
/// process-local serialization for `call_tool`.
struct WorkspaceToolDispatcher: Sendable {
    /// Reports a tool task abandoned by a timeout that may still be running. The lane owner uses
    /// it to keep the Workspace closed until the task ends.
    typealias AbandonedToolHandler = @Sendable (Task<Void, Never>) -> Void
    typealias LocalExecutor = @Sendable (AnyTool, [String: AnyCodable], AbandonedToolHandler) async throws -> String

    static let callName = "call_tool"

    private let timelineManager: TimelineManager

    init(timelineManager: TimelineManager) {
        self.timelineManager = timelineManager
    }

    /// Resolves a provider-facing dispatcher call exclusively against the admission snapshot.
    /// The returned value contains everything needed to record durable intent before execution.
    func prepare(
        call: ParsedToolCall,
        catalog: WorkspaceToolCatalog
    ) throws -> WorkspaceToolDispatch {
        guard call.name == Self.callName, !catalog.isEmpty else {
            throw ToolError.toolNotFound(call.name)
        }
        guard let arguments = call.arguments else {
            throw ToolError.malformedArguments("invalid JSON object")
        }
        guard let requestedTool = arguments["tool"]?.asString,
              !requestedTool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ToolError.missingArgument("tool")
        }

        let requestedWorkspace: UUID?
        let explicit: Bool
        if let at = arguments["at"] {
            explicit = true
            guard let value = at.asString,
                  let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                throw ToolError.invalidWorkspaceID(at.description)
            }
            requestedWorkspace = id
        } else {
            explicit = false
            requestedWorkspace = nil
        }

        if explicit, let requestedWorkspace,
           !catalog.entries.contains(where: { $0.workspace.id == requestedWorkspace })
        {
            throw ToolError.workspaceNotFound(requestedWorkspace)
        }

        let matches = catalog.entries.flatMap { entry in
            entry.tools
                .filter { $0.callName == requestedTool }
                .map { (entry: entry, tool: $0) }
        }
        guard !matches.isEmpty else { throw ToolError.toolNotFound(requestedTool) }
        guard matches.count == 1 else {
            let sortedMatches = matches.sorted {
                ($0.entry.workspace.id.uuidString, $0.entry.label, $0.tool.callName, $0.tool.name)
                    < ($1.entry.workspace.id.uuidString, $1.entry.label, $1.tool.callName, $1.tool.name)
            }
            throw ToolError.ambiguousWorkspaceTool(
                tool: requestedTool,
                candidates: sortedMatches.map { match in
                    ToolError.AmbiguousWorkspaceCandidate(
                        workspaceID: match.entry.workspace.id,
                        label: match.entry.label,
                        toolName: match.tool.name,
                        description: match.tool.toolDescription,
                        parametersSchema: match.tool.parametersSchema.asDictionary,
                        isPrimary: match.entry.isPrimary
                    )
                }
            )
        }

        let match = matches[0]
        if let requestedWorkspace, match.entry.workspace.id != requestedWorkspace {
            throw ToolError.toolNotFound(requestedTool)
        }
        return WorkspaceToolDispatch(
            route: WorkspaceToolRoute(
                workspaceID: match.entry.workspace.id,
                tool: match.tool,
                explicit: explicit,
                isPrimary: match.entry.isPrimary,
                location: match.entry.workspace.location
            ),
            arguments: arguments
        )
    }

    /// Executes a prepared dispatch after its caller has persisted intent.
    func execute(
        _ dispatch: WorkspaceToolDispatch,
        timelineID: UUID,
        using executeLocally: @escaping LocalExecutor
    ) async throws -> ToolExecutionOutcome {
        let arguments = dispatch.arguments
        guard let nested = arguments["arguments"]?.asDictionary ??
            (arguments["arguments"] == nil ? [:] : nil)
        else {
            throw ToolError.invalidArgument(
                "arguments",
                expected: "object",
                got: arguments["arguments"]?.description ?? "null"
            )
        }

        let route = dispatch.route
        switch try executionDisposition(
            location: route.location,
            timelineIsPrivate: await timelineManager.timeline(id: timelineID)?.isPrivate ?? false
        ) {
        case .executeLocally:
            let output = try await timelineManager.withWorkspaceExecution(route.workspaceID) {
                if !route.isPrimary {
                    try await timelineManager.requireWorkspaceBinding(route.workspaceID, for: timelineID)
                }
                return try await executeLocally(route.tool, nested) { task in
                    timelineManager.retainWorkspaceLane(route.workspaceID, until: task)
                }
            }
            return .completed(output)
        case .deferExternally:
            return .deferredExternally
        }
    }

    /// Applies the same Workspace lane to Agent-primary tools exposed directly to the provider.
    func executeDirect(
        tool: AnyTool,
        arguments: [String: AnyCodable],
        using executeLocally: @escaping LocalExecutor
    ) async throws -> String {
        guard case let .workspace(workspaceID, _) = tool.origin else {
            return try await executeLocally(tool, arguments, { _ in })
        }
        return try await timelineManager.withWorkspaceExecution(workspaceID) {
            try await executeLocally(tool, arguments) { task in
                timelineManager.retainWorkspaceLane(workspaceID, until: task)
            }
        }
    }

    private func executionDisposition(
        location: WorkspaceReference.WorkspaceLocation,
        timelineIsPrivate: Bool
    ) throws -> WorkspaceExecutionDisposition {
        switch location {
        case .runtime, .runtimeTimeline:
            return .executeLocally
        case .attached:
            guard !timelineIsPrivate else {
                throw ToolError.attachedToolsDisallowedOnPrivateTimeline
            }
            return .deferExternally
        }
    }
}

/// Marker tool exposed to the model for workspace-only dispatch.
///
/// The router consumes this marker before normal tool execution. Its implementation is a guard
/// against accidental direct execution if a future call path forgets to use the dispatcher.
private struct WorkspaceCallTool: PKTool, Sendable {
    let toolIDs: [String]

    let callName = WorkspaceToolDispatcher.callName
    let name = "Workspace Tool"
    let toolDescription = "Call a Workspace tool by an exact advertised call name. Omit 'at' only when that name identifies one Workspace."
    let requiresPermission = false
    let sideEffects: ToolSideEffects = .mutating
    let usageExample: String? = nil

    init(toolIDs: [String]) {
        self.toolIDs = toolIDs
    }

    var parametersSchema: Schema {
        Schema([
            "type": .string("object"),
            "properties": .dictionary([
                "tool": .dictionary([
                    "type": .string("string"),
                    "enum": .array(toolIDs.map { .string($0) }),
                ]),
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

/// Whether a captured Workspace executes locally or defers to its attached host.
private enum WorkspaceExecutionDisposition {
    case executeLocally
    case deferExternally
}

extension TimelineManager {
    private static let reservedAgentWorkspaceToolNames: Set<String> = [
        "read_file", "list_files", "search_files", "write_file", "append_file", "edit_file", "delete_file",
    ]

    /// Captures the authorized workspace tools used by an admitted Turn. When no Agent primary
    /// Workspace is supplied, this contains only ordinary Workspaces bound to the Timeline.
    ///
    /// The caller invokes this from the same admission authority lane used for Agent and Timeline
    /// mutations. Workspace references and tool wrappers are copied into the returned value before
    /// the durable Turn admission is committed.
    func captureWorkspaceToolCatalog(
        for timelineID: UUID,
        primaryWorkspaceID: UUID?
    ) async throws -> WorkspaceToolCatalog {
        let query = try await getWorkspaces(for: timelineID)
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
        let registry = toolManagers[timelineID]
        var entries: [WorkspaceToolCatalog.Entry] = []

        for (reference, isPrimary) in references {
            var tools: [AnyTool] = []

            // The primary Agent workspace is not an ordinary Timeline binding, so hydrate its
            // wrappers directly. This also fills any custom definitions unavailable in the
            // Timeline registry while preserving known system tools where applicable.
            var fileProvider: any WorkspaceFileProvider?
            var liveWorkspace: any WorkspaceProvider?
            do {
                liveWorkspace = try await workspaceResolver.workspace(id: reference.id)
            } catch {
                recordCatalogDegradation(
                    for: timelineID, operation: "resolveWorkspace", workspaceID: reference.id, error: error
                )
            }
            fileProvider = liveWorkspace as? any WorkspaceFileProvider
            if isPrimary, fileProvider == nil, reference.rootPath != nil {
                do {
                    fileProvider = try LocalAgentWorkspaceProvider(reference: reference)
                } catch {
                    recordCatalogDegradation(
                        for: timelineID, operation: "localFileProvider", workspaceID: reference.id, error: error
                    )
                }
            }
            if let toolProvider = liveWorkspace as? any WorkspaceToolProvider
            {
                do {
                    let listed = try await toolProvider.listTools()
                    for toolReference in listed {
                        switch toolReference {
                        case let .known(id):
                            if let registry,
                               let known = await registry.toolForKnownWorkspaceReference(id: id)
                            {
                                tools.append(known.withOrigin(.workspace(id: reference.id, name: reference.uri.description)))
                            }
                        case let .custom(definition):
                            tools.append(AnyTool(
                                WorkspaceToolWrapper(workspace: toolProvider, definition: definition),
                                origin: .workspace(id: reference.id, name: reference.uri.description)
                            ))
                        }
                    }
                } catch {
                    recordCatalogDegradation(
                        for: timelineID, operation: "listTools", workspaceID: reference.id, error: error
                    )
                }
            }

            // Agent primary workspaces always receive the guarded generic filesystem surface.
            // These names are reserved so a workspace-provided definition cannot silently replace
            // a path-jailed built-in or bypass the configured protected-path approval gate.
            var genericTools: [AnyTool] = []
            if isPrimary, let fileProvider {
                let origin = ToolOrigin.workspace(id: reference.id, name: reference.uri.description)
                let protectedPaths = runtimeToolPolicy.protectedPrimaryWorkspacePaths
                genericTools = AgentWorkspaceFileTool.Operation.all.map { operation in
                    AnyTool(
                        AgentWorkspaceFileTool(
                            operation: operation,
                            provider: fileProvider,
                            protectedPaths: protectedPaths
                        ),
                        origin: origin
                    )
                }
            }

            let workspaceTools = tools.filter { tool in
                !isPrimary || !Self.reservedAgentWorkspaceToolNames.contains(tool.callName)
            }
            tools = genericTools + workspaceTools
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

    /// Records a catalog-capture failure through the same degradation lane the attach path uses,
    /// so a resolver or `listTools` failure is observable instead of being silently swallowed by
    /// a `try?`. The Turn degradation policy decides whether the recorded diagnostic is fatal.
    private func recordCatalogDegradation(
        for timelineID: UUID,
        operation: String,
        workspaceID: UUID,
        error: Error
    ) {
        logger.warning("""
        captureWorkspaceToolCatalog: \(operation) failed — \
        workspace: \(workspaceID.uuidString.prefix(8)), timeline: \(timelineID.uuidString.prefix(8)), \
        error: \(ErrorKit.userFriendlyMessage(for: error))
        """)
        timelineDegradations[timelineID, default: []].append(TurnDiagnostic(
            dependency: .workspace,
            operation: "captureWorkspaceCatalog.\(operation)",
            entityID: "workspace:\(workspaceID.uuidString.prefix(8))",
            error: error
        ))
    }
}
