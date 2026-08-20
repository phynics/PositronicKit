import Foundation
import PKContracts
import PKUtilities

/// Thread-safe in-memory workspace persistence for prototyping and development.
public actor InMemoryWorkspacePersistence: WorkspaceStore, WorkspaceBindingRepository {
    private var workspaces: [WorkspaceReference] = []
    private var bindingsByWorkspace: [UUID: WorkspaceBinding] = [:]
    private var workspaceIDsByThread: [UUID: Set<UUID>] = [:]

    public init() {}

    public func saveWorkspace(_ workspace: WorkspaceReference) async throws {
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
    }

    public func fetchWorkspace(id: UUID, includeTools _: Bool = false) async throws -> WorkspaceReference? {
        workspaces.first { $0.id == id }
    }

    public func fetchAllWorkspaces() async throws -> [WorkspaceReference] {
        workspaces
    }

    public func deleteWorkspace(id: UUID) async throws {
        workspaces.removeAll { $0.id == id }
        if let binding = bindingsByWorkspace.removeValue(forKey: id) {
            workspaceIDsByThread[binding.threadID]?.remove(id)
            if workspaceIDsByThread[binding.threadID]?.isEmpty == true {
                workspaceIDsByThread.removeValue(forKey: binding.threadID)
            }
        }
    }

    package func allWorkspaces() -> [WorkspaceReference] {
        workspaces
    }

    package func replaceWorkspaces(_ workspaces: [WorkspaceReference]) {
        self.workspaces = workspaces
    }

    // MARK: WorkspaceBindingRepository

    public func claim(
        workspaceID: UUID,
        for threadID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        if let existing = bindingsByWorkspace[workspaceID] {
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
        bindingsByWorkspace[workspaceID] = binding
        workspaceIDsByThread[threadID, default: []].insert(workspaceID)
        return binding
    }

    public func release(
        workspaceID: UUID,
        from threadID: UUID,
        now _: Date = Date()
    ) async throws {
        guard let existing = bindingsByWorkspace[workspaceID], existing.threadID == threadID else {
            throw WorkspaceBindingRepositoryError.bindingNotFound(
                workspaceID: workspaceID,
                threadID: threadID
            )
        }
        bindingsByWorkspace.removeValue(forKey: workspaceID)
        workspaceIDsByThread[threadID]?.remove(workspaceID)
        if workspaceIDsByThread[threadID]?.isEmpty == true {
            workspaceIDsByThread.removeValue(forKey: threadID)
        }
    }

    public func transfer(
        workspaceID: UUID,
        from sourceThreadID: UUID,
        to destinationThreadID: UUID,
        now: Date = Date()
    ) async throws -> WorkspaceBinding {
        guard let existing = bindingsByWorkspace[workspaceID], existing.threadID == sourceThreadID else {
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
        bindingsByWorkspace[workspaceID] = binding
        workspaceIDsByThread[sourceThreadID]?.remove(workspaceID)
        if workspaceIDsByThread[sourceThreadID]?.isEmpty == true {
            workspaceIDsByThread.removeValue(forKey: sourceThreadID)
        }
        workspaceIDsByThread[destinationThreadID, default: []].insert(workspaceID)
        return binding
    }

    public func bindings(for threadID: UUID) async throws -> [WorkspaceBinding] {
        (workspaceIDsByThread[threadID] ?? [])
            .compactMap { bindingsByWorkspace[$0] }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func threadID(for workspaceID: UUID) async throws -> UUID? {
        bindingsByWorkspace[workspaceID]?.threadID
    }
}
