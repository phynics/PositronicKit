import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

/// Manages the lifecycle of agent instances: creation, attachment to threads,
/// detachment, and deletion.
///
/// Attachment rules:
/// - Each thread can have at most one attached agent (exclusive lock).
/// - One agent can attach to multiple threads simultaneously.
/// - `attach` is idempotent: re-attaching the same agent to the same thread is a no-op.
/// - If `attachedAgentId` references a deleted agent, it is nulled on access.
public actor AgentManager: AgentManagerProtocol {
    public struct Stores: Sendable {
        public let instanceStore: any AgentStoreProtocol
        public let threadStore: any ThreadPersistenceProtocol
        public let messageStore: any ThreadMessageStoreProtocol
        public let workspaceStore: any WorkspaceStore

        public init(
            instanceStore: any AgentStoreProtocol,
            threadStore: any ThreadPersistenceProtocol,
            messageStore: any ThreadMessageStoreProtocol,
            workspaceStore: any WorkspaceStore
        ) {
            self.instanceStore = instanceStore
            self.threadStore = threadStore
            self.messageStore = messageStore
            self.workspaceStore = workspaceStore
        }

    }

    private let instanceStore: any AgentStoreProtocol
    private let threadStore: any ThreadPersistenceProtocol
    private let messageStore: any ThreadMessageStoreProtocol
    private let workspaceStore: any WorkspaceStore

    private let repository: any WorkspaceCatalog
    /// When non-nil, private-thread deletion routes through `ThreadManager.evictThreadFromMemory(id:)`
    /// so the in-memory caches and prompt-history registry entry are evicted alongside persistence,
    /// not just the persisted row (PKR-3).
    private let threadManager: ThreadManager?
    private let logger = Logger.module(named: "agent-instance-manager")

    public init(
        repository: any WorkspaceCatalog,
        stores: Stores,
        threadManager: ThreadManager? = nil
    ) {
        self.repository = repository
        self.instanceStore = stores.instanceStore
        self.threadStore = stores.threadStore
        self.messageStore = stores.messageStore
        self.workspaceStore = stores.workspaceStore
        self.threadManager = threadManager
    }

    public init(repository: any WorkspaceCatalog) {
        self.init(
            repository: repository,
            stores: .init(
                instanceStore: InMemoryAgentStore(),
                threadStore: InMemoryThreadPersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: InMemoryWorkspacePersistence()
            )
        )
    }

    // MARK: - Create

    /// Creates a new agent instance, its private workspace, and its private thread atomically.
    /// If a later write fails, completed (and attempted) writes are compensated in reverse order;
    /// cleanup failures are logged while the original creation error is rethrown.
    /// - Parameters:
    ///   - template: Optional `AgentTemplate` template to seed workspace files from.
    ///   - name: Display name for the instance.
    ///   - description: Purpose description.
    /// - Returns: The created `Agent`.
    public func createInstance(
        from template: AgentTemplate?,
        name: String,
        description: String
    ) async throws -> Agent {
        try validate(name: name, description: description)

        let instanceId = UUID()
        let privateThreadID = UUID()

        var workspace: WorkspaceReference?
        var didAttemptThreadSave = false
        var didAttemptInstanceSave = false
        var didAttemptAuditSave = false

        do {
            // 1. Create workspace via repository
            let createdWorkspace = try await repository.createAgentWorkspace(
                instanceID: instanceId,
                template: template
            )
            workspace = createdWorkspace

            // 2. Persist private thread
            let privateThread = Thread(
                id: privateThreadID,
                title: "[\(name)] Private",
                attachedWorkspaceIDs: [createdWorkspace.id],
                attachedAgentID: instanceId,
                isPrivate: true
            )
            didAttemptThreadSave = true
            try await threadStore.saveThread(privateThread)

            // 3. Persist agent instance
            let instance = Agent(
                id: instanceId,
                name: name,
                description: description,
                primaryWorkspaceID: createdWorkspace.id,
                privateThreadID: privateThreadID
            )
            didAttemptInstanceSave = true
            try await instanceStore.saveAgent(instance)

            // 4. Log creation to private thread
            let creationMsg = ThreadMessage(
                threadID: privateThreadID,
                role: .system,
                content: "[CREATED] Agent instance '\(name)' (\(instanceId.uuidString)) created."
            )
            didAttemptAuditSave = true
            try await messageStore.saveMessage(creationMsg)

            logger.info("Created agent instance '\(name)' (\(instanceId))")
            return instance
        } catch {
            await rollbackCreateInstance(
                instanceID: instanceId,
                privateThreadID: privateThreadID,
                workspace: workspace,
                didAttemptThreadSave: didAttemptThreadSave,
                didAttemptInstanceSave: didAttemptInstanceSave,
                didAttemptAuditSave: didAttemptAuditSave,
                originalError: error
            )
            throw error
        }
    }

    // MARK: - Attach / Detach

    /// Attaches an agent instance to a thread.
    ///
    /// - Idempotent: no-op if the same agent is already attached.
    /// - Fails if a different agent is attached (caller must detach it first).
    /// - If `attachedAgentId` references a non-existent agent, it is cleared automatically.
    public func attach(agentID: UUID, to threadID: UUID) async throws {
        guard var thread = try await threadStore.fetchThread(id: threadID) else {
            throw AgentError.threadNotFound(threadID)
        }
        guard let agent = try await instanceStore.fetchAgent(id: agentID) else {
            throw AgentError.instanceNotFound(agentID)
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
            if try await instanceStore.fetchAgent(id: existingId) != nil {
                throw AgentError.differentAgentAlreadyAttached(existingId)
            }
            // Dangling reference — clear it with a warning
            logger.warning(
                "Clearing dangling agent reference \(existingId) on thread \(threadID)")
        }

        thread.attachedAgentID = agentID
        thread.updatedAt = Date()
        try await threadStore.saveThread(thread)

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

    /// Detaches an agent instance from a thread.
    /// No-op if the agent is not attached to that thread.
    public func detach(agentID: UUID, from threadID: UUID) async throws {
        guard var thread = try await threadStore.fetchThread(id: threadID) else {
            throw AgentError.threadNotFound(threadID)
        }

        guard thread.attachedAgentID == agentID else { return }

        // Prevent detaching an agent from its own private thread
        if thread.isPrivate, thread.attachedAgentID == agentID {
            throw AgentError.cannotDetachFromOwnPrivateThread(threadID)
        }

        thread.attachedAgentID = nil
        thread.updatedAt = Date()
        try await threadStore.saveThread(thread)

        // Log to agent's private thread if it still exists
        if let agent = try? await instanceStore.fetchAgent(id: agentID) {
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

    public func instance(id: UUID) async throws -> Agent? {
        try await instanceStore.fetchAgent(id: id)
    }

    public func getInstance(id: UUID) async throws -> Agent? {
        try await instance(id: id)
    }

    public func listInstances() async throws -> [Agent] {
        try await instanceStore.fetchAllAgents()
    }

    public func threads(attachedTo agentID: UUID) async throws -> [Thread] {
        try await fetchAttachedThreads(for: agentID)
    }


    public func getThreads(attachedTo agentID: UUID) async throws -> [Thread] {
        try await threads(attachedTo: agentID)
    }

    public func updateInstance(_ instance: Agent) async throws {
        try validate(name: instance.name, description: instance.description)
        var updated = instance
        updated.updatedAt = Date()
        try await instanceStore.saveAgent(updated)
    }

    public func searchInstances(query: String) async throws -> [Agent] {
        let all = try await listInstances()
        if query.isEmpty { return all }
        let lowerQuery = query.lowercased()
        return all.filter {
            $0.name.lowercased().contains(lowerQuery)
                || $0.description.lowercased().contains(lowerQuery)
                || $0.id.uuidString.lowercased().contains(lowerQuery)
        }
    }

    // MARK: - Helpers

    private func rollbackCreateInstance(
        instanceID: UUID,
        privateThreadID: UUID,
        workspace: WorkspaceReference?,
        didAttemptThreadSave: Bool,
        didAttemptInstanceSave: Bool,
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
                    instanceID: instanceID,
                    originalError: originalError,
                    cleanupError: error
                )
            }
        }

        // Stores may report a failed save after the row was written; deletes are therefore
        // attempted for every save that was entered, not only for saves that returned success.
        if didAttemptInstanceSave {
            do {
                try await instanceStore.deleteAgent(id: instanceID)
            } catch {
                logCreateRollbackFailure(
                    operation: "deleteAgent",
                    entityID: instanceID,
                    instanceID: instanceID,
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
                    instanceID: instanceID,
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
                    instanceID: instanceID,
                    originalError: originalError,
                    cleanupError: error
                )
            }
        }
    }

    private func logCreateRollbackFailure(
        operation: String,
        entityID: UUID,
        instanceID: UUID,
        originalError: Error,
        cleanupError: Error
    ) {
        var metadata = LoggingMetadata.makeMetadata(
            for: cleanupError,
            correlationID: instanceID.uuidString
        )
        metadata[LogKeys.stage] = .string("createInstance.rollback")
        metadata["operation"] = .string(operation)
        metadata["entityID"] = .string(entityID.uuidString)

        logger.error(
            """
            createInstance rollback failed — operation: \(operation), entity: \(entityID.uuidString.prefix(8)), \
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

    // MARK: - Delete

    /// Deletes an agent instance and optionally force-detaches it from all threads.
    /// - Parameters:
    ///   - id: The agent instance identifier to delete.
    ///   - force: If false, throws if the agent is still attached to any threads.
    public func deleteInstance(id: UUID, force: Bool) async throws {
        guard let instance = try await instanceStore.fetchAgent(id: id) else {
            throw AgentError.instanceNotFound(id)
        }

        let allAttached = try await fetchAttachedThreads(for: id)
        // Exclude the agent's own private thread from the "still attached" check
        let nonPrivateAttached = allAttached.filter { $0.id != instance.privateThreadID }

        if !nonPrivateAttached.isEmpty, !force {
            throw AgentError.hasAttachedThreads(count: nonPrivateAttached.count)
        }

        // Force-detach from non-private threads
        for var thread in nonPrivateAttached {
            thread.attachedAgentID = nil
            thread.updatedAt = Date()
            try await threadStore.saveThread(thread)
        }

        // Delete the private thread before the workspace or agent record. If this fails,
        // preserve the agent and its workspace so the operation can be retried without
        // leaving a persisted thread pointing at a removed agent.
        do {
            try await threadStore.deleteThread(id: instance.privateThreadID)
        } catch {
            logger.error(
                "Failed to delete private thread \(instance.privateThreadID) for agent \(id): \(ErrorKit.userFriendlyMessage(for: error))")
            throw error
        }

        // Evict the in-memory caches + prompt-history registry via the ThreadManager seam
        // when available (PKR-3), after the persisted row has been deleted successfully.
        if let threadManager {
            await threadManager.evictThreadFromMemory(id: instance.privateThreadID)
        }

        // Delete primary workspace directory (high risk IO)
        if let workspaceId = instance.primaryWorkspaceID {
            do {
                try await repository.deleteWorkspace(id: workspaceId, deleteDirectory: true)
            } catch {
                logger.error("Failed to delete workspace directory for agent \(id): \(error)")
            }
        }

        // Delete database record
        try await instanceStore.deleteAgent(id: id)
        logger.info("Deleted agent instance \(id)")
    }
}
