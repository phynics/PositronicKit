import Foundation
import PKContracts

/// Stateful Thread entry points exposed by ``PositronicKit``.
public struct ThreadCapability: Sendable {
    private let kit: PositronicKit

    init(kit: PositronicKit) {
        self.kit = kit
    }

    /// Creates and persists a Thread, returning its stable handle.
    ///
    /// When `agentID` is supplied, the Agent must be active. The operation validates the Agent
    /// before durable creation and returns only after the Thread row contains the attachment, so
    /// managed execution can begin immediately from the returned handle.
    ///
    /// - Parameters:
    ///   - title: The title to persist for the new Thread.
    ///   - agentID: An existing Agent that owns the managed execution authority, if any.
    /// - Returns: A handle for the newly created Thread.
    public func create(
        title: String = "New Thread",
        attaching agentID: UUID? = nil
    ) async throws -> ThreadHandle {
        let thread = if let agentID {
            try await kit.agentManager.createThread(title: title, attaching: agentID)
        } else {
            try await kit.threadManager.createThread(title: title)
        }
        return open(thread.id)
    }

    /// Opens a handle without performing persistence I/O.
    public func open(_ threadID: UUID) -> ThreadHandle {
        ThreadHandle(threadID: threadID, kit: kit)
    }

    /// Lists persisted Threads.
    public func list(includeArchived: Bool = true) async throws -> [Thread] {
        try await kit.threadManager.threadStore.fetchAllThreads(includeArchived: includeArchived)
    }

    /// Reads one cached or persisted Thread.
    public func get(_ threadID: UUID) async throws -> Thread? {
        try await kit.threadManager.threadStore.fetchThread(id: threadID)
    }

    /// Reads durable Thread messages in oldest-first order.
    ///
    /// An unknown Thread ID returns an empty array. The result is durable Thread history, not
    /// the assembled prompt state observed by ``PromptJournal``.
    public func messages(for threadID: UUID) async throws -> [ThreadMessage] {
        try await kit.messageStore.fetchMessages(for: threadID)
    }

    /// Renames a Thread while preserving its existing handle.
    public func rename(_ threadID: UUID, to title: String) async throws {
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
