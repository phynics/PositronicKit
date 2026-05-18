import Foundation
import PKShared

/// Pure routing-policy helpers used by `ToolRouter`.
///
/// This type centralizes the decision points that do not require side effects:
/// selecting the effective tool reference for a parsed call and deciding whether a resolved
/// workspace location implies runtime-local execution or external deferral.
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
}

enum WorkspaceExecutionDisposition: Sendable {
    case executeLocally
    case deferExternally
}
