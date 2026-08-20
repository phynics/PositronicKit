import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

/// Manages the lifecycle of agents: creation, attachment to threads,
/// detachment, and deletion.
///
/// Attachment rules:
/// - Each thread can have at most one attached agent (exclusive lock).
/// - One agent can attach to multiple threads simultaneously.
/// - `attach` is idempotent: re-attaching the same agent to the same thread is a no-op.
/// - If `attachedAgentId` references a deleted agent, it is nulled on access.
actor AgentManager: AgentManagerProtocol {
    public struct Stores: Sendable {
        public let agentStore: any AgentStoreProtocol
        public let threadStore: any ThreadPersistenceProtocol
        public let messageStore: any ThreadMessageStoreProtocol
        public let workspaceStore: any WorkspaceStore
        public let runtimeRepository: (any ThreadRuntimeRepository)?
        public let threadAuthorityCoordinator: ThreadAuthorityCoordinator?

        public init(
            agentStore: any AgentStoreProtocol,
            threadStore: any ThreadPersistenceProtocol,
            messageStore: any ThreadMessageStoreProtocol,
            workspaceStore: any WorkspaceStore,
            runtimeRepository: (any ThreadRuntimeRepository)? = nil,
            threadAuthorityCoordinator: ThreadAuthorityCoordinator? = nil
        ) {
            self.agentStore = agentStore
            self.threadStore = threadStore
            self.messageStore = messageStore
            self.workspaceStore = workspaceStore
            self.runtimeRepository = runtimeRepository
            self.threadAuthorityCoordinator = threadAuthorityCoordinator
        }

    }

    private let agentStore: any AgentStoreProtocol
    private let threadStore: any ThreadPersistenceProtocol
    private let messageStore: any ThreadMessageStoreProtocol
    private let workspaceStore: any WorkspaceStore
    private let runtimeRepository: (any ThreadRuntimeRepository)?
    private let threadAuthorityCoordinator: ThreadAuthorityCoordinator

    private let repository: any WorkspaceCatalog
    /// When non-nil, private-thread deletion routes through `ThreadManager.evictThreadFromMemory(id:)`
    /// so the in-memory caches and prompt-history registry entry are evicted alongside persistence,
    /// not just the persisted row (PKR-3).
    private let threadManager: ThreadManager?
    private let logger = Logger.module(named: "agent-manager")

    public init(
        repository: any WorkspaceCatalog,
        stores: Stores,
        threadManager: ThreadManager? = nil
    ) {
        self.repository = repository
        self.agentStore = stores.agentStore
        self.threadStore = stores.threadStore
        self.messageStore = stores.messageStore
        self.workspaceStore = stores.workspaceStore
        self.runtimeRepository = stores.runtimeRepository
        self.threadAuthorityCoordinator = stores.threadAuthorityCoordinator
            ?? threadManager?.threadAuthorityCoordinator
            ?? ThreadAuthorityCoordinator()
        self.threadManager = threadManager
    }

    public init(repository: any WorkspaceCatalog) {
        self.init(
            repository: repository,
            stores: .init(
                agentStore: InMemoryAgentStore(),
                threadStore: InMemoryThreadPersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: InMemoryWorkspacePersistence()
            )
        )
    }

    // MARK: - Create

    /// Creates a new agent, its private workspace, and its private thread atomically.
    /// If a later write fails, completed (and attempted) writes are compensated in reverse order;
    /// cleanup failures are logged while the original creation error is rethrown.
    /// - Parameters:
    ///   - template: Optional `AgentTemplate` template to seed workspace files from.
    ///   - name: Display name for the agent.
    ///   - description: Purpose description.
    /// - Returns: The created `Agent`.
    public func createAgent(
        from template: AgentTemplate?,
        name: String,
        description: String
    ) async throws -> Agent {
        try validate(name: name, description: description)

        let agentId = UUID()
        let privateThreadID = UUID()

        var workspace: WorkspaceReference?
        var didAttemptThreadSave = false
        var didAttemptAgentSave = false
        var didAttemptAuditSave = false

        do {
            // 1. Create workspace via repository
            let createdWorkspace = try await repository.createAgentWorkspace(
                agentID: agentId,
                template: template
            )
            workspace = createdWorkspace

            // 2. Persist private thread
            let privateThread = Thread(
                id: privateThreadID,
                title: "[\(name)] Private",
                // An Agent's primary workspace is owned by the Agent record, not by an
                // ordinary Thread binding. Keep the private Thread's binding set empty.
                attachedWorkspaceIDs: [],
                attachedAgentID: agentId,
                isPrivate: true
            )
            didAttemptThreadSave = true
            try await threadStore.saveThread(privateThread)

            // 3. Persist agent
            let agent = Agent(
                id: agentId,
                name: name,
                description: description,
                primaryWorkspaceID: createdWorkspace.id,
                privateThreadID: privateThreadID
            )
            didAttemptAgentSave = true
            try await agentStore.saveAgent(agent)

            // 4. Log creation to private thread
            let creationMsg = ThreadMessage(
                threadID: privateThreadID,
                role: .system,
                content: "[CREATED] Agent '\(name)' (\(agentId.uuidString)) created."
            )
            didAttemptAuditSave = true
            try await messageStore.saveMessage(creationMsg)

            logger.info("Created agent '\(name)' (\(agentId))")
            return agent
        } catch {
            await rollbackCreateAgent(
                agentID: agentId,
                privateThreadID: privateThreadID,
                workspace: workspace,
                didAttemptThreadSave: didAttemptThreadSave,
                didAttemptAgentSave: didAttemptAgentSave,
                didAttemptAuditSave: didAttemptAuditSave,
                originalError: error
            )
            throw error
        }
    }

    // MARK: - Attach / Detach

    /// Attaches an agent to a thread.
    ///
    /// - Idempotent: no-op if the same agent is already attached.
    /// - Fails if a different agent is attached (caller must detach it first).
    /// - If `attachedAgentId` references a non-existent agent, it is cleared automatically.
    public func attach(agentID: UUID, to threadID: UUID) async throws {
        try await requireExecutionContextMutable(for: threadID)
        guard let thread = try await threadStore.fetchThread(id: threadID) else {
            throw AgentError.threadNotFound(threadID)
        }
        guard let agent = try await agentStore.fetchAgent(id: agentID) else {
            throw AgentError.agentNotFound(agentID)
        }

        // Idempotent
        if thread.attachedAgentID == agentID { return }

        // Prevent attaching an agent to a private thread owned by another agent
        if thread.isPrivate {
            if let currentOwner = thread.attachedAgentID, currentOwner != agentID {
                throw AgentError.cannotAttachToPrivateThread(threadID)
            }
        }

        // Check for existing attachment
        if let existingId = thread.attachedAgentID {
            if try await agentStore.fetchAgent(id: existingId) != nil {
                throw AgentError.differentAgentAlreadyAttached(existingId)
            }
            // Dangling reference — clear it with a warning
            logger.warning(
                "Clearing dangling agent reference \(existingId) on thread \(threadID)")
        }

        let originalThread = thread
        try await threadAuthorityCoordinator.withThread(threadID) { [self, originalThread] in
            try await self.requireExecutionContextMutable(for: threadID)
            var updated = originalThread
            updated.attachedAgentID = agentID
            updated.updatedAt = Date()
            try await self.threadStore.saveThread(updated)
        }

        // Log to agent's private thread
        let logMsg = ThreadMessage(
            threadID: agent.privateThreadID,
            role: .system,
            content: "[ATTACH] Agent '\(agent.name)' (\(agentID.uuidString.prefix(8))) "
                + "attached to thread \"\(thread.title)\" (\(threadID.uuidString.prefix(8)))"
        )
        do {
            try await messageStore.saveMessage(logMsg)
        } catch {
            logger.warning(
                "Failed to persist attach audit log for agent \(agentID) on thread \(threadID) (private thread \(agent.privateThreadID)): \(ErrorKit.userFriendlyMessage(for: error))")
        }

        logger.info("Agent '\(agent.name)' attached to thread '\(thread.title)'")
    }

    /// Detaches an agent from a thread.
    /// No-op if the agent is not attached to that thread.
    public func detach(agentID: UUID, from threadID: UUID) async throws {
        try await requireExecutionContextMutable(for: threadID)
        guard let thread = try await threadStore.fetchThread(id: threadID) else {
            throw AgentError.threadNotFound(threadID)
        }

        guard thread.attachedAgentID == agentID else { return }

        // Prevent detaching an agent from its own private thread
        if thread.isPrivate, thread.attachedAgentID == agentID {
            throw AgentError.cannotDetachFromOwnPrivateThread(threadID)
        }

        let originalThread = thread
        try await threadAuthorityCoordinator.withThread(threadID) { [self, originalThread] in
            try await self.requireExecutionContextMutable(for: threadID)
            var updated = originalThread
            updated.attachedAgentID = nil
            updated.updatedAt = Date()
            try await self.threadStore.saveThread(updated)
        }

        // Log to agent's private thread if it still exists
        if let agent = try? await agentStore.fetchAgent(id: agentID) {
            let logMsg = ThreadMessage(
                threadID: agent.privateThreadID,
                role: .system,
                content: "[DETACH] Agent '\(agent.name)' detached from thread "
                    + "\"\(thread.title)\" (\(threadID.uuidString.prefix(8)))"
            )
            do {
                try await messageStore.saveMessage(logMsg)
            } catch {
                logger.warning(
                    "Failed to persist detach audit log for agent \(agentID) on thread \(threadID) (private thread \(agent.privateThreadID)): \(ErrorKit.userFriendlyMessage(for: error))")
            }
            logger.info("Agent '\(agent.name)' detached from thread '\(thread.title)'")
        }
    }

    // MARK: - Queries

    public func agent(id: UUID) async throws -> Agent? {
        try await agentStore.fetchAgent(id: id)
    }

    public func getAgent(id: UUID) async throws -> Agent? {
        try await agent(id: id)
    }

    public func listAgents() async throws -> [Agent] {
        try await agentStore.fetchAllAgents()
    }

    public func threads(attachedTo agentID: UUID) async throws -> [Thread] {
        try await fetchAttachedThreads(for: agentID)
    }


    public func getThreads(attachedTo agentID: UUID) async throws -> [Thread] {
        try await threads(attachedTo: agentID)
    }

    public func updateAgent(_ agent: Agent) async throws {
        try validate(name: agent.name, description: agent.description)
        var updated = agent
        updated.updatedAt = Date()
        try await agentStore.saveAgent(updated)
    }

    public func searchAgents(query: String) async throws -> [Agent] {
        let all = try await listAgents()
        if query.isEmpty { return all }
        let lowerQuery = query.lowercased()
        return all.filter {
            $0.name.lowercased().contains(lowerQuery)
                || $0.description.lowercased().contains(lowerQuery)
                || $0.id.uuidString.lowercased().contains(lowerQuery)
        }
    }

    // MARK: - Helpers

    private func rollbackCreateAgent(
        agentID: UUID,
        privateThreadID: UUID,
        workspace: WorkspaceReference?,
        didAttemptThreadSave: Bool,
        didAttemptAgentSave: Bool,
        didAttemptAuditSave: Bool,
        originalError: Error
    ) async {
        // The audit save may have failed after writing, so compensate an attempted save too.
        if didAttemptAuditSave {
            do {
                try await messageStore.deleteMessages(for: privateThreadID)
            } catch {
                logCreateRollbackFailure(
                    operation: "deleteMessages",
                    entityID: privateThreadID,
                    agentID: agentID,
                    originalError: originalError,
                    cleanupError: error
                )
            }
        }

        // Stores may report a failed save after the row was written; deletes are therefore
        // attempted for every save that was entered, not only for saves that returned success.
        if didAttemptAgentSave {
            do {
                try await agentStore.deleteAgent(id: agentID)
            } catch {
                logCreateRollbackFailure(
                    operation: "deleteAgent",
                    entityID: agentID,
                    agentID: agentID,
                    originalError: originalError,
                    cleanupError: error
                )
            }
        }

        if didAttemptThreadSave {
            do {
                try await threadStore.deleteThread(id: privateThreadID)
            } catch {
                logCreateRollbackFailure(
                    operation: "deleteThread",
                    entityID: privateThreadID,
                    agentID: agentID,
                    originalError: originalError,
                    cleanupError: error
                )
            }
        }

        if let workspace {
            do {
                try await repository.deleteWorkspace(id: workspace.id, deleteDirectory: true)
            } catch {
                logCreateRollbackFailure(
                    operation: "deleteWorkspace",
                    entityID: workspace.id,
                    agentID: agentID,
                    originalError: originalError,
                    cleanupError: error
                )
            }
        }
    }

    private func logCreateRollbackFailure(
        operation: String,
        entityID: UUID,
        agentID: UUID,
        originalError: Error,
        cleanupError: Error
    ) {
        var metadata = LoggingMetadata.makeMetadata(
            for: cleanupError,
            correlationID: agentID.uuidString
        )
        metadata[LogKeys.stage] = .string("createAgent.rollback")
        metadata["operation"] = .string(operation)
        metadata["entityID"] = .string(entityID.uuidString)

        logger.error(
            """
            createAgent rollback failed — operation: \(operation), entity: \(entityID.uuidString.prefix(8)), \
            original error: \(ErrorKit.userFriendlyMessage(for: originalError)), \
            cleanup error: \(ErrorKit.userFriendlyMessage(for: cleanupError))
            """,
            metadata: metadata
        )
    }

    private func fetchAttachedThreads(for agentID: UUID) async throws -> [Thread] {
        let allThreads = try await threadStore.fetchAllThreads(includeArchived: true)
        return allThreads.filter { $0.attachedAgentID == agentID }
    }

    private func validate(name: String, description: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.count < 3 {
            throw AgentError.nameTooShort(trimmedName)
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AgentError.descriptionEmpty
        }
    }

    private func requireExecutionContextMutable(for threadID: UUID) async throws {
        if let threadManager {
            try await threadManager.requireExecutionContextMutable(for: threadID)
        } else if let runtimeRepository,
                  let activeTurn = try await runtimeRepository.fetchActiveTurn(for: threadID)
        {
            throw ThreadRuntimeRepositoryError.threadBusy(
                threadID: threadID,
                activeTurnID: activeTurn.identity.turnID
            )
        }
    }

    // MARK: - Delete

    /// Deletes an agent and optionally force-detaches it from all threads.
    /// - Parameters:
    ///   - id: The agent identifier to delete.
    ///   - force: If false, throws if the agent is still attached to any threads.
    public func deleteAgent(id: UUID, force: Bool) async throws {
        guard let agent = try await agentStore.fetchAgent(id: id) else {
            throw AgentError.agentNotFound(id)
        }

        let allAttached = try await fetchAttachedThreads(for: id)
        // Exclude the agent's own private thread from the "still attached" check
        let nonPrivateAttached = allAttached.filter { $0.id != agent.privateThreadID }

        if !nonPrivateAttached.isEmpty, !force {
            throw AgentError.hasAttachedThreads(count: nonPrivateAttached.count)
        }

        // Force-detach from non-private threads
        for thread in nonPrivateAttached {
            let originalThread = thread
            try await threadAuthorityCoordinator.withThread(thread.id) { [self, originalThread] in
                try await self.requireExecutionContextMutable(for: originalThread.id)
                var updated = originalThread
                updated.attachedAgentID = nil
                updated.updatedAt = Date()
                try await self.threadStore.saveThread(updated)
            }
        }

        // Delete the private thread before the workspace or agent record. If this fails,
        // preserve the agent and its workspace so the operation can be retried without
        // leaving a persisted thread pointing at a removed agent.
        do {
            try await threadStore.deleteThread(id: agent.privateThreadID)
        } catch {
            logger.error(
                "Failed to delete private thread \(agent.privateThreadID) for agent \(id): \(ErrorKit.userFriendlyMessage(for: error))")
            throw error
        }

        // Evict the in-memory caches + prompt-history registry via the ThreadManager seam
        // when available (PKR-3), after the persisted row has been deleted successfully.
        if let threadManager {
            await threadManager.evictThreadFromMemory(id: agent.privateThreadID)
        }

        // Delete primary workspace directory (high risk IO)
        if let workspaceId = agent.primaryWorkspaceID {
            do {
                try await repository.deleteWorkspace(id: workspaceId, deleteDirectory: true)
            } catch {
                logger.error("Failed to delete workspace directory for agent \(id): \(error)")
            }
        }

        // Delete database record
        try await agentStore.deleteAgent(id: id)
        logger.info("Deleted agent \(id)")
    }
}
