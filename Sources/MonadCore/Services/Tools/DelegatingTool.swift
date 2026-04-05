import Foundation
import MonadShared

/// A Tool implementation that delegates execution to a ToolRouter
public struct DelegatingTool: Tool, ToolReferenceProviding {
    public let ref: ToolReference
    private let router: ToolRouter
    private let timelineId: UUID
    private let resolvedDefinition: WorkspaceToolDefinition

    public init(
        ref: ToolReference,
        router: ToolRouter,
        timelineId: UUID,
        resolvedDefinition: WorkspaceToolDefinition
    ) {
        self.ref = ref
        self.router = router
        self.timelineId = timelineId
        self.resolvedDefinition = resolvedDefinition
    }

    // MARK: - Tool Protocol

    public var toolReference: ToolReference {
        ref
    }

    public var id: String {
        ref.toolId
    }

    public var name: String {
        resolvedDefinition.name
    }

    public var description: String {
        resolvedDefinition.description
    }

    public var requiresPermission: Bool {
        resolvedDefinition.requiresPermission
    }

    public var usageExample: String? {
        resolvedDefinition.usageExample
    }

    public func canExecute() async -> Bool {
        true // Assume available if routed
    }

    public var parametersSchema: [String: AnyCodable] {
        resolvedDefinition.parametersSchema
    }

    public func execute(parameters: [String: Any]) async throws -> ToolResult {
        let args = parameters.mapValues { AnyCodable($0) }

        do {
            let outcome = try await router.execute(tool: ref, arguments: args, timelineId: timelineId)
            switch outcome {
            case let .completed(output):
                return .success(output)
            case .deferredToClient:
                // This path should never be reached: client tools are dispatched by
                // handlePendingToolCalls() before DelegatingTool.execute() is called.
                assertionFailure("DelegatingTool.execute() reached .deferredToClient — this is a logic error")
                throw ToolError.executionFailed(
                    "Tool '\(ref.toolId)' must be executed client-side via handlePendingToolCalls"
                )
            }
        } catch let error as ToolError {
            return .failure(error.localizedDescription)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
