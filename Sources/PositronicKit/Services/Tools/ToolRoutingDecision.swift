import Foundation
import Logging
import PKShared

/// Pure routing-policy helpers + workspace-resolution seam used by `ToolRouter`.
///
/// This type centralizes the decision points that `ToolRouter` owned before PKARCH-002:
/// selecting the effective tool reference for a parsed call, deciding whether a resolved
/// workspace location implies runtime-local execution or external deferral, and resolving
/// which workspace a tool should execute against (including explicit `workspaceID` argument
/// handling and dynamic-tool fallback).
///
/// The workspace-resolution methods are async and reach through a ``WorkspaceResolutionProvider``
/// seam so they can be tested with in-memory fakes without bringing up a `TimelineManager`.
enum ToolRoutingDecision {
    static func resolveToolReference(
        for call: ParsedToolCall,
        availableTools: [AnyTool]
    ) -> ToolReference {
        availableTools.first(where: { $0.id == call.name })?.toolReference
            ?? ToolReference.known(id: call.name)
    }

    static func outcomeForWorkspace(
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

    /// Resolves the workspace to execute `tool` against for a given timeline.
    ///
    /// Resolution order:
    /// 1. If the caller supplied an explicit `workspaceID` argument, it must match one of the
    ///    timeline's candidate workspace ids; otherwise `ToolError.workspaceNotFound` is thrown
    ///    (YAK-33 fail-closed).
    /// 2. Otherwise, defer to the provider's `findWorkspaceForTool(_:in:)` lookup over the
    ///    candidate list (primary first, then attached in declared order).
    /// 3. Returns `nil` if the timeline has no workspaces, or if no candidate workspace
    ///    registers the tool. `ToolRouter.execute` interprets `nil` as `toolNotFound`.
    ///
    /// `availableTools` is the per-turn dynamic-tool list. When one of those tools matches the
    /// reference, the caller (`ToolRouter.execute`) short-circuits before this resolution is
    /// called; this function still takes the list for symmetry/diagnostic use but does not
    /// consult it for routing.
    static func resolveWorkspace(
        for tool: ToolReference,
        in timelineId: UUID,
        arguments: [String: AnyCodable],
        provider: any WorkspaceResolutionProvider,
        logger: Logger
    ) async throws -> UUID? {
        let resolved = try await provider.workspaces(for: timelineId)
        guard let wsList = resolved else { return nil }

        let candidates = ([wsList.primary].compactMap { $0?.id }) + wsList.attached.map { $0.id }

        // Check for explicit intent in arguments.
        if let explicitIdString = arguments["workspaceID"]?.value as? String,
           let explicitId = UUID(uuidString: explicitIdString.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            guard candidates.contains(explicitId) else {
                throw ToolError.workspaceNotFound(explicitId)
            }

            logger.debug("Routing to explicitly requested workspace: \(explicitId)")
            return explicitId
        }

        return try await provider.findWorkspaceForTool(tool, in: candidates)
    }
}

/// Read-only seam over the workspace-attachment + tool-persistence lookups that
/// `ToolRoutingDecision.resolveWorkspace` needs. `TimelineManager` conforms (it already exposes
/// `getWorkspaces(for:)`, `getWorkspace(_:)`, `findWorkspaceForTool(_:in:)`, and `getTimeline(id:)`
/// as public methods). Tests substitute an in-memory fake.
package protocol WorkspaceResolutionProvider: Sendable {
    /// Returns the primary + attached workspaces for `timelineId`, or `nil` if the timeline is
    /// not known to the provider.
    func workspaces(for timelineId: UUID) async throws -> (
        primary: WorkspaceReference?,
        attached: [WorkspaceReference]
    )?

    /// Returns the workspace id (within `candidates`) that registers `tool`, or `nil` if none.
    func findWorkspaceForTool(_ tool: ToolReference, in candidates: [UUID]) async throws -> UUID?

    /// Returns the cached `Timeline` for `timelineId`, or `nil` if it is not resident. Used by
    /// `ToolRouter.execute` to read `isPrivate`; included here so the routing decision does not
    /// need a separate `TimelineManager` dependency.
    func timelineIsPrivate(id: UUID) async -> Bool?

    /// Returns the `TimelineToolManager` cached for `timelineId`, or `nil`. Forwarded by
    /// `ToolRouter` to `ToolExecutor`'s lookup closure.
    func toolManager(for timelineId: UUID) async -> TimelineToolManager?

    /// Fetches the workspace reference by id (delegates to the workspace store).
    func getWorkspace(_ id: UUID) async throws -> WorkspaceReference?
}

extension TimelineManager: WorkspaceResolutionProvider {
    package func workspaces(for timelineId: UUID) async throws -> (
        primary: WorkspaceReference?,
        attached: [WorkspaceReference]
    )? {
        await getWorkspaces(for: timelineId)
    }

    package func timelineIsPrivate(id: UUID) async -> Bool? {
        await getTimeline(id: id)?.isPrivate
    }

    package func toolManager(for timelineId: UUID) async -> TimelineToolManager? {
        getToolManager(for: timelineId)
    }
}

enum WorkspaceExecutionDisposition: Sendable {
    case executeLocally
    case deferExternally
}
