import Foundation

/// Actor-backed Workspace binding repository for local hosts and tests.
///
/// The actor models the atomic conditional claim that a durable adapter must provide. It does
/// not infer Agent ownership: callers only claim ordinary Thread bindings here.
public actor InMemoryWorkspaceBindingRepository: WorkspaceBindingRepository {
    private var byWorkspace: [UUID: WorkspaceBinding] = [:]
    private var byThread: [UUID: Set<UUID>] = [:]

    public init() {}

    public func claim(
        workspaceID: UUID,
        for threadID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        if let existing = byWorkspace[workspaceID] {
            guard existing.threadID == threadID else {
                throw WorkspaceBindingRepositoryError.workspaceAlreadyBound(
                    workspaceID: workspaceID,
                    threadID: existing.threadID
                )
            }
            return existing
        }

        let binding = WorkspaceBinding(
            workspaceID: workspaceID,
            threadID: threadID,
            createdAt: now,
            updatedAt: now
        )
        byWorkspace[workspaceID] = binding
        byThread[threadID, default: []].insert(workspaceID)
        return binding
    }

    public func release(
        workspaceID: UUID,
        from threadID: UUID,
        now _: Date = Date()
    ) async throws {
        guard let existing = byWorkspace[workspaceID], existing.threadID == threadID else {
            throw WorkspaceBindingRepositoryError.bindingNotFound(
                workspaceID: workspaceID,
                threadID: threadID
            )
        }
        byWorkspace.removeValue(forKey: workspaceID)
        byThread[threadID]?.remove(workspaceID)
        if byThread[threadID]?.isEmpty == true {
            byThread.removeValue(forKey: threadID)
        }
    }

    public func transfer(
        workspaceID: UUID,
        from sourceThreadID: UUID,
        to destinationThreadID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        guard let existing = byWorkspace[workspaceID], existing.threadID == sourceThreadID else {
            throw WorkspaceBindingRepositoryError.transferSourceMismatch(
                workspaceID: workspaceID,
                threadID: sourceThreadID
            )
        }
        let binding = WorkspaceBinding(
            workspaceID: workspaceID,
            threadID: destinationThreadID,
            createdAt: existing.createdAt,
            updatedAt: now
        )
        byWorkspace[workspaceID] = binding
        byThread[sourceThreadID]?.remove(workspaceID)
        if byThread[sourceThreadID]?.isEmpty == true {
            byThread.removeValue(forKey: sourceThreadID)
        }
        byThread[destinationThreadID, default: []].insert(workspaceID)
        return binding
    }

    public func bindings(for threadID: UUID) async throws -> [WorkspaceBinding] {
        (byThread[threadID] ?? [])
            .compactMap { byWorkspace[$0] }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func threadID(for workspaceID: UUID) async throws -> UUID? {
        byWorkspace[workspaceID]?.threadID
    }
}
