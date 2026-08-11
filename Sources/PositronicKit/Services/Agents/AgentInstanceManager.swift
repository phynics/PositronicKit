import ErrorKit
import Foundation
import Logging
import PKShared
import PKUtilities

/// Manages the lifecycle of agent instances: creation, attachment to timelines,
/// detachment, and deletion.
///
/// Attachment rules:
/// - Each timeline can have at most one attached agent (exclusive lock).
/// - One agent can attach to multiple timelines simultaneously.
/// - `attach` is idempotent: re-attaching the same agent to the same timeline is a no-op.
/// - If `attachedAgentInstanceId` references a deleted agent, it is nulled on access.
public actor AgentInstanceManager: AgentInstanceManagerProtocol {
    public struct Stores: Sendable {
        public let instanceStore: any AgentInstanceStoreProtocol
        public let timelineStore: any TimelinePersistenceProtocol
        public let messageStore: any MessageStoreProtocol
        public let workspaceStore: any WorkspaceStore

        public init(
            instanceStore: any AgentInstanceStoreProtocol,
            timelineStore: any TimelinePersistenceProtocol,
            messageStore: any MessageStoreProtocol,
            workspaceStore: any WorkspaceStore
        ) {
            self.instanceStore = instanceStore
            self.timelineStore = timelineStore
            self.messageStore = messageStore
            self.workspaceStore = workspaceStore
        }
    }

    private let instanceStore: any AgentInstanceStoreProtocol
    private let timelineStore: any TimelinePersistenceProtocol
    private let messageStore: any MessageStoreProtocol
    private let workspaceStore: any WorkspaceStore

    private let repository: any WorkspaceCatalog
    /// When non-nil, private-timeline deletion routes through `TimelineManager.evictTimelineFromMemory(id:)`
    /// so the in-memory caches and prompt-history registry entry are evicted alongside persistence,
    /// not just the persisted row (PKR-3).
    private let timelineManager: TimelineManager?
    private let logger = Logger.module(named: "agent-instance-manager")

    public init(
        repository: any WorkspaceCatalog,
        stores: Stores,
        timelineManager: TimelineManager? = nil
    ) {
        self.repository = repository
        self.instanceStore = stores.instanceStore
        self.timelineStore = stores.timelineStore
        self.messageStore = stores.messageStore
        self.workspaceStore = stores.workspaceStore
        self.timelineManager = timelineManager
    }

    public init(repository: any WorkspaceCatalog) {
        self.init(
            repository: repository,
            stores: .init(
                instanceStore: InMemoryAgentInstanceStore(),
                timelineStore: InMemoryTimelinePersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: InMemoryWorkspacePersistence()
            )
        )
    }

    // MARK: - Create

    /// Creates a new agent instance, its private workspace, and its private timeline atomically.
    /// If a later write fails, completed (and attempted) writes are compensated in reverse order;
    /// cleanup failures are logged while the original creation error is rethrown.
    /// - Parameters:
    ///   - template: Optional `AgentTemplate` template to seed workspace files from.
    ///   - name: Display name for the instance.
    ///   - description: Purpose description.
    /// - Returns: The created `AgentInstance`.
    public func createInstance(
        from template: AgentTemplate?,
        name: String,
        description: String
    ) async throws -> AgentInstance {
        try validate(name: name, description: description)

        let instanceId = UUID()
        let privateTimelineId = UUID()

        var workspace: WorkspaceReference?
        var didAttemptTimelineSave = false
        var didAttemptInstanceSave = false
        var didAttemptAuditSave = false

        do {
            // 1. Create workspace via repository
            let createdWorkspace = try await repository.createAgentWorkspace(
                instanceId: instanceId,
                template: template
            )
            workspace = createdWorkspace

            // 2. Persist private timeline
            let privateTimeline = Timeline(
                id: privateTimelineId,
                title: "[\(name)] Private",
                attachedWorkspaceIDs: [createdWorkspace.id],
                attachedAgentInstanceID: instanceId,
                isPrivate: true
            )
            didAttemptTimelineSave = true
            try await timelineStore.saveTimeline(privateTimeline)

            // 3. Persist agent instance
            let instance = AgentInstance(
                id: instanceId,
                name: name,
                description: description,
                primaryWorkspaceID: createdWorkspace.id,
                privateTimelineID: privateTimelineId
            )
            didAttemptInstanceSave = true
            try await instanceStore.saveAgentInstance(instance)

            // 4. Log creation to private timeline
            let creationMsg = ConversationMessage(
                timelineID: privateTimelineId,
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
                privateTimelineID: privateTimelineId,
                workspace: workspace,
                didAttemptTimelineSave: didAttemptTimelineSave,
                didAttemptInstanceSave: didAttemptInstanceSave,
                didAttemptAuditSave: didAttemptAuditSave,
                originalError: error
            )
            throw error
        }
    }

    // MARK: - Attach / Detach

    /// Attaches an agent instance to a timeline.
    ///
    /// - Idempotent: no-op if the same agent is already attached.
    /// - Fails if a different agent is attached (caller must detach it first).
    /// - If `attachedAgentInstanceId` references a non-existent agent, it is cleared automatically.
    public func attach(agentID: UUID, to timelineID: UUID) async throws {
        guard var timeline = try await timelineStore.fetchTimeline(id: timelineID) else {
            throw AgentInstanceError.timelineNotFound(timelineID)
        }
        guard let agent = try await instanceStore.fetchAgentInstance(id: agentID) else {
            throw AgentInstanceError.instanceNotFound(agentID)
        }

        // Idempotent
        if timeline.attachedAgentInstanceID == agentID { return }

        // Prevent attaching an agent to a private timeline owned by another agent
        if timeline.isPrivate {
            if let currentOwner = timeline.attachedAgentInstanceID, currentOwner != agentID {
                throw AgentInstanceError.cannotAttachToPrivateTimeline(timelineID)
            }
        }

        // Check for existing attachment
        if let existingId = timeline.attachedAgentInstanceID {
            if try await instanceStore.fetchAgentInstance(id: existingId) != nil {
                throw AgentInstanceError.differentAgentAlreadyAttached(existingId)
            }
            // Dangling reference — clear it with a warning
            logger.warning(
                "Clearing dangling agent reference \(existingId) on timeline \(timelineID)")
        }

        timeline.attachedAgentInstanceID = agentID
        timeline.updatedAt = Date()
        try await timelineStore.saveTimeline(timeline)

        // Log to agent's private timeline
        let logMsg = ConversationMessage(
            timelineID: agent.privateTimelineID,
            role: .system,
            content: "[ATTACH] Agent '\(agent.name)' (\(agentID.uuidString.prefix(8))) "
                + "attached to timeline \"\(timeline.title)\" (\(timelineID.uuidString.prefix(8)))"
        )
        do {
            try await messageStore.saveMessage(logMsg)
        } catch {
            logger.warning(
                "Failed to persist attach audit log for agent \(agentID) on timeline \(timelineID) (private timeline \(agent.privateTimelineID)): \(ErrorKit.userFriendlyMessage(for: error))")
        }

        logger.info("Agent '\(agent.name)' attached to timeline '\(timeline.title)'")
    }

    /// Attaches an agent instance using the legacy identifier spellings.
    @_disfavoredOverload
    @available(*, deprecated, message: "Use attach(agentID:to:).")
    public func attach(agentId: UUID, to timelineId: UUID) async throws {
        try await attach(agentID: agentId, to: timelineId)
    }

    /// Detaches an agent instance from a timeline.
    /// No-op if the agent is not attached to that timeline.
    public func detach(agentID: UUID, from timelineID: UUID) async throws {
        guard var timeline = try await timelineStore.fetchTimeline(id: timelineID) else {
            throw AgentInstanceError.timelineNotFound(timelineID)
        }

        guard timeline.attachedAgentInstanceID == agentID else { return }

        // Prevent detaching an agent from its own private timeline
        if timeline.isPrivate, timeline.attachedAgentInstanceID == agentID {
            throw AgentInstanceError.cannotDetachFromOwnPrivateTimeline(timelineID)
        }

        timeline.attachedAgentInstanceID = nil
        timeline.updatedAt = Date()
        try await timelineStore.saveTimeline(timeline)

        // Log to agent's private timeline if it still exists
        if let agent = try? await instanceStore.fetchAgentInstance(id: agentID) {
            let logMsg = ConversationMessage(
                timelineID: agent.privateTimelineID,
                role: .system,
                content: "[DETACH] Agent '\(agent.name)' detached from timeline "
                    + "\"\(timeline.title)\" (\(timelineID.uuidString.prefix(8)))"
            )
            do {
                try await messageStore.saveMessage(logMsg)
            } catch {
                logger.warning(
                    "Failed to persist detach audit log for agent \(agentID) on timeline \(timelineID) (private timeline \(agent.privateTimelineID)): \(ErrorKit.userFriendlyMessage(for: error))")
            }
            logger.info("Agent '\(agent.name)' detached from timeline '\(timeline.title)'")
        }
    }

    /// Detaches an agent instance using the legacy identifier spellings.
    @_disfavoredOverload
    @available(*, deprecated, message: "Use detach(agentID:from:).")
    public func detach(agentId: UUID, from timelineId: UUID) async throws {
        try await detach(agentID: agentId, from: timelineId)
    }

    // MARK: - Queries

    public func instance(id: UUID) async throws -> AgentInstance? {
        try await instanceStore.fetchAgentInstance(id: id)
    }

    @available(*, deprecated, renamed: "instance(id:)")
    public func getInstance(id: UUID) async throws -> AgentInstance? {
        try await instance(id: id)
    }

    public func listInstances() async throws -> [AgentInstance] {
        try await instanceStore.fetchAllAgentInstances()
    }

    public func timelines(attachedTo agentID: UUID) async throws -> [Timeline] {
        try await fetchAttachedTimelines(for: agentID)
    }

    @available(*, deprecated, renamed: "timelines(attachedTo:)")
    public func getTimelines(attachedTo agentId: UUID) async throws -> [Timeline] {
        try await timelines(attachedTo: agentId)
    }

    public func updateInstance(_ instance: AgentInstance) async throws {
        try validate(name: instance.name, description: instance.description)
        var updated = instance
        updated.updatedAt = Date()
        try await instanceStore.saveAgentInstance(updated)
    }

    public func searchInstances(query: String) async throws -> [AgentInstance] {
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
        privateTimelineID: UUID,
        workspace: WorkspaceReference?,
        didAttemptTimelineSave: Bool,
        didAttemptInstanceSave: Bool,
        didAttemptAuditSave: Bool,
        originalError: Error
    ) async {
        // The audit save may have failed after writing, so compensate an attempted save too.
        if didAttemptAuditSave {
            do {
                try await messageStore.deleteMessages(for: privateTimelineID)
            } catch {
                logCreateRollbackFailure(
                    operation: "deleteMessages",
                    entityID: privateTimelineID,
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
                try await instanceStore.deleteAgentInstance(id: instanceID)
            } catch {
                logCreateRollbackFailure(
                    operation: "deleteAgentInstance",
                    entityID: instanceID,
                    instanceID: instanceID,
                    originalError: originalError,
                    cleanupError: error
                )
            }
        }

        if didAttemptTimelineSave {
            do {
                try await timelineStore.deleteTimeline(id: privateTimelineID)
            } catch {
                logCreateRollbackFailure(
                    operation: "deleteTimeline",
                    entityID: privateTimelineID,
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

    private func fetchAttachedTimelines(for agentID: UUID) async throws -> [Timeline] {
        let allTimelines = try await timelineStore.fetchAllTimelines(includeArchived: true)
        return allTimelines.filter { $0.attachedAgentInstanceID == agentID }
    }

    private func validate(name: String, description: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.count < 3 {
            throw AgentInstanceError.nameTooShort(trimmedName)
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AgentInstanceError.descriptionEmpty
        }
    }

    // MARK: - Delete

    /// Deletes an agent instance and optionally force-detaches it from all timelines.
    /// - Parameters:
    ///   - id: The agent instance identifier to delete.
    ///   - force: If false, throws if the agent is still attached to any timelines.
    public func deleteInstance(id: UUID, force: Bool) async throws {
        guard let instance = try await instanceStore.fetchAgentInstance(id: id) else {
            throw AgentInstanceError.instanceNotFound(id)
        }

        let allAttached = try await fetchAttachedTimelines(for: id)
        // Exclude the agent's own private timeline from the "still attached" check
        let nonPrivateAttached = allAttached.filter { $0.id != instance.privateTimelineID }

        if !nonPrivateAttached.isEmpty, !force {
            throw AgentInstanceError.hasAttachedTimelines(count: nonPrivateAttached.count)
        }

        // Force-detach from non-private timelines
        for var timeline in nonPrivateAttached {
            timeline.attachedAgentInstanceID = nil
            timeline.updatedAt = Date()
            try await timelineStore.saveTimeline(timeline)
        }

        // Delete the private timeline before the workspace or agent record. If this fails,
        // preserve the agent and its workspace so the operation can be retried without
        // leaving a persisted timeline pointing at a removed agent.
        do {
            try await timelineStore.deleteTimeline(id: instance.privateTimelineID)
        } catch {
            logger.error(
                "Failed to delete private timeline \(instance.privateTimelineID) for agent \(id): \(ErrorKit.userFriendlyMessage(for: error))")
            throw error
        }

        // Evict the in-memory caches + prompt-history registry via the TimelineManager seam
        // when available (PKR-3), after the persisted row has been deleted successfully.
        if let timelineManager {
            await timelineManager.evictTimelineFromMemory(id: instance.privateTimelineID)
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
        try await instanceStore.deleteAgentInstance(id: id)
        logger.info("Deleted agent instance \(id)")
    }
}
