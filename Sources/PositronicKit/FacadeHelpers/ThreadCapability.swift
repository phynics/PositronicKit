import Foundation
import PKContracts

/// Stateful Thread entry points exposed by ``PositronicKit``.
public struct ThreadCapability: Sendable {
    private let kit: PositronicKit

    init(kit: PositronicKit) {
        self.kit = kit
    }

    /// Creates and persists a Thread, returning its stable handle.
    public func create(title: String = "New Thread") async throws -> ThreadHandle {
        let thread = try await kit.threadManager.createThread(title: title)
        return kit.openThread(thread.id)
    }

    /// Opens a handle without performing persistence I/O.
    public func open(_ threadID: UUID) -> ThreadHandle {
        kit.openThread(threadID)
    }

    /// Lists persisted Threads.
    public func list(includeArchived: Bool = true) async throws -> [Thread] {
        try await kit.threadManager.threadStore.fetchAllThreads(includeArchived: includeArchived)
    }

    /// Reads one cached or persisted Thread.
    public func get(_ threadID: UUID) async throws -> Thread? {
        try await kit.threadManager.threadStore.fetchThread(id: threadID)
    }

    /// Renames a Thread while preserving its existing handle.
    public func rename(_ threadID: UUID, title: String) async throws {
        try await kit.threadManager.updateThreadTitle(threadID, title: title)
    }

    /// Attaches an ordinary Workspace to a Thread.
    public func attachWorkspace(_ workspaceID: UUID, to threadID: UUID) async throws {
        try await kit.threadManager.attachWorkspace(workspaceID, to: threadID)
    }

    /// Detaches an ordinary Workspace from a Thread.
    public func detachWorkspace(_ workspaceID: UUID, from threadID: UUID) async throws {
        try await kit.threadManager.detachWorkspace(workspaceID, from: threadID)
    }
}
