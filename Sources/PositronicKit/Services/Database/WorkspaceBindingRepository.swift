import Foundation
import PKContracts

/// The durable relationship between an ordinary workspace and a Timeline.
///
/// A workspace can have at most one ordinary binding, while a Timeline may own many bindings.
/// Agent primary workspaces are intentionally not represented by this value; their ownership is
/// carried by the Agent record instead.
public struct WorkspaceBinding: Codable, Equatable, Hashable, Sendable {
    public let workspaceID: UUID
    public let timelineID: UUID
    public let createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case timelineID = "threadID"
        case createdAt, updatedAt
    }

    public init(
        workspaceID: UUID,
        timelineID: UUID,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.workspaceID = workspaceID
        self.timelineID = timelineID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Errors raised by the atomic Workspace binding boundary.
public enum WorkspaceBindingRepositoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case workspaceAlreadyBound(workspaceID: UUID, timelineID: UUID)
    case bindingNotFound(workspaceID: UUID, timelineID: UUID)
    case transferSourceMismatch(workspaceID: UUID, timelineID: UUID)

    private struct ErrorMetadata {
        let code: Int
        let message: String
    }

    private var errorMetadata: ErrorMetadata {
        switch self {
        case let .workspaceAlreadyBound(workspaceID, timelineID):
            return ErrorMetadata(code: 3101, message: "Workspace \(workspaceID) is already bound to Timeline \(timelineID).")
        case let .bindingNotFound(workspaceID, timelineID):
            return ErrorMetadata(code: 3102, message: "Workspace \(workspaceID) is not bound to Timeline \(timelineID).")
        case let .transferSourceMismatch(workspaceID, timelineID):
            return ErrorMetadata(code: 3103, message: "Workspace \(workspaceID) cannot transfer from Timeline \(timelineID).")
        }
    }

    public var description: String {
        errorMetadata.message
    }
}

/// Stable `PKError` identity for Workspace binding repository failures.
extension WorkspaceBindingRepositoryError: PKError {
    public var errorDomain: String {
        PKErrorDomain.workspace
    }

    public var errorCode: Int {
        errorMetadata.code
    }

    public var userFriendlyMessage: String {
        errorMetadata.message
    }
}

/// Durable authority for ordinary workspace-to-Timeline relationships.
///
/// Each mutating operation is the conditional-claim boundary. Implementations backed by a
/// database must enforce the same uniqueness constraint in their transaction, not by reading
/// and then writing in separate calls.
public protocol WorkspaceBindingRepository: DurabilityAware {
    func claim(
        workspaceID: UUID,
        for timelineID: UUID,
        now: Date
    ) async throws -> WorkspaceBinding

    func release(
        workspaceID: UUID,
        from timelineID: UUID,
        now: Date
    ) async throws

    func transfer(
        workspaceID: UUID,
        from sourceTimelineID: UUID,
        to destinationTimelineID: UUID,
        now: Date
    ) async throws -> WorkspaceBinding

    func bindings(for timelineID: UUID) async throws -> [WorkspaceBinding]
    func timelineID(for workspaceID: UUID) async throws -> UUID?
}
