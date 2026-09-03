import Foundation

/// The durable relationship between an ordinary workspace and a Thread.
///
/// A workspace can have at most one ordinary binding, while a Thread may own many bindings.
/// Agent primary workspaces are intentionally not represented by this value; their ownership is
/// carried by the Agent record instead.
public struct WorkspaceBinding: Codable, Equatable, Hashable, Sendable {
    public let workspaceID: UUID
    public let threadID: UUID
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        workspaceID: UUID,
        threadID: UUID,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.workspaceID = workspaceID
        self.threadID = threadID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Errors raised by the atomic Workspace binding boundary.
public enum WorkspaceBindingRepositoryError: Error, Equatable, Sendable, CustomStringConvertible {
    case workspaceAlreadyBound(workspaceID: UUID, threadID: UUID)
    case bindingNotFound(workspaceID: UUID, threadID: UUID)
    case transferSourceMismatch(workspaceID: UUID, threadID: UUID)

    public var description: String {
        switch self {
        case let .workspaceAlreadyBound(workspaceID, threadID):
            return "Workspace \(workspaceID) is already bound to Thread \(threadID)."
        case let .bindingNotFound(workspaceID, threadID):
            return "Workspace \(workspaceID) is not bound to Thread \(threadID)."
        case let .transferSourceMismatch(workspaceID, threadID):
            return "Workspace \(workspaceID) cannot transfer from Thread \(threadID)."
        }
    }
}

/// Durable authority for ordinary workspace-to-Thread relationships.
///
/// Each mutating operation is the conditional-claim boundary. Implementations backed by a
/// database must enforce the same uniqueness constraint in their transaction, not by reading
/// and then writing in separate calls.
public protocol WorkspaceBindingRepository: DurabilityAware {
    func claim(
        workspaceID: UUID,
        for threadID: UUID,
        now: Date
    ) async throws -> WorkspaceBinding

    func release(
        workspaceID: UUID,
        from threadID: UUID,
        now: Date
    ) async throws

    func transfer(
        workspaceID: UUID,
        from sourceThreadID: UUID,
        to destinationThreadID: UUID,
        now: Date
    ) async throws -> WorkspaceBinding

    func bindings(for threadID: UUID) async throws -> [WorkspaceBinding]
    func threadID(for workspaceID: UUID) async throws -> UUID?
}
