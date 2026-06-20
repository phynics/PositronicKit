import ErrorKit
import Foundation
import Logging
import PKShared

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
        public let workspaceStore: any WorkspacePersistenceProtocol

        public init(
            instanceStore: any AgentInstanceStoreProtocol,
            timelineStore: any TimelinePersistenceProtocol,
            messageStore: any MessageStoreProtocol,
            workspaceStore: any WorkspacePersistenceProtocol
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
    private let workspaceStore: any WorkspacePersistenceProtocol

    private let repository: any AgentWorkspaceServiceProtocol
    private let logger = Logger.module(named: "agent-instance-manager")

    public init(
        repository: any AgentWorkspaceServiceProtocol,
        stores: Stores
    ) {
        self.repository = repository
        self.instanceStore = stores.instanceStore
        self.timelineStore = stores.timelineStore
        self.messageStore = stores.messageStore
        self.workspaceStore = stores.workspaceStore
    }

    public init(repository: any AgentWorkspaceServiceProtocol) {
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

        // 1. Create workspace via repository
        let workspace = try await repository.createAgentWorkspace(
            instanceId: instanceId,
            template: template
        )

        // 2. Persist private timeline
        let privateTimeline = Timeline(
            id: privateTimelineId,
            title: "[\(name)] Private",
            attachedWorkspaceIds: [workspace.id],
            attachedAgentInstanceId: instanceId,
            isPrivate: true
        )
        try await timelineStore.saveTimeline(privateTimeline)

        // 3. Persist agent instance
        let instance = AgentInstance(
            id: instanceId,
            name: name,
            description: description,
            primaryWorkspaceId: workspace.id,
            privateTimelineId: privateTimelineId
        )
        try await instanceStore.saveAgentInstance(instance)

        // 4. Log creation to private timeline
        let creationMsg = ConversationMessage(
            timelineId: privateTimelineId,
            role: .system,
            content: "[CREATED] Agent instance '\(name)' (\(instanceId.uuidString)) created."
        )
        try await messageStore.saveMessage(creationMsg)

        logger.info("Created agent instance '\(name)' (\(instanceId))")
        return instance
    }

    // MARK: - Attach / Detach

    /// Attaches an agent instance to a timeline.
    ///
    /// - Idempotent: no-op if the same agent is already attached.
    /// - Fails if a different agent is attached (caller must detach it first).
    /// - If `attachedAgentInstanceId` references a non-existent agent, it is cleared automatically.
    public func attach(agentId: UUID, to timelineId: UUID) async throws {
        guard var timeline = try await timelineStore.fetchTimeline(id: timelineId) else {
            throw AgentInstanceError.timelineNotFound(timelineId)
        }
        guard let agent = try await instanceStore.fetchAgentInstance(id: agentId) else {
            throw AgentInstanceError.instanceNotFound(agentId)
        }

        // Idempotent
        if timeline.attachedAgentInstanceId == agentId { return }

        // Prevent attaching an agent to a private timeline owned by another agent
        if timeline.isPrivate {
            if let currentOwner = timeline.attachedAgentInstanceId, currentOwner != agentId {
                throw AgentInstanceError.cannotAttachToPrivateTimeline(timelineId)
            }
        }

        // Check for existing attachment
        if let existingId = timeline.attachedAgentInstanceId {
            if try await instanceStore.fetchAgentInstance(id: existingId) != nil {
                throw AgentInstanceError.differentAgentAlreadyAttached(existingId)
            }
            // Dangling reference — clear it with a warning
            logger.warning(
                "Clearing dangling agent reference \(existingId) on timeline \(timelineId)")
        }

        timeline.attachedAgentInstanceId = agentId
        timeline.updatedAt = Date()
        try await timelineStore.saveTimeline(timeline)

        // Log to agent's private timeline
        let logMsg = ConversationMessage(
            timelineId: agent.privateTimelineId,
            role: .system,
            content: "[ATTACH] Agent '\(agent.name)' (\(agentId.uuidString.prefix(8))) "
                + "attached to timeline \"\(timeline.title)\" (\(timelineId.uuidString.prefix(8)))"
        )
        try? await messageStore.saveMessage(logMsg)

        logger.info("Agent '\(agent.name)' attached to timeline '\(timeline.title)'")
    }

    /// Detaches an agent instance from a timeline.
    /// No-op if the agent is not attached to that timeline.
    public func detach(agentId: UUID, from timelineId: UUID) async throws {
        guard var timeline = try await timelineStore.fetchTimeline(id: timelineId) else {
            throw AgentInstanceError.timelineNotFound(timelineId)
        }

        guard timeline.attachedAgentInstanceId == agentId else { return }

        // Prevent detaching an agent from its own private timeline
        if timeline.isPrivate, timeline.attachedAgentInstanceId == agentId {
            throw AgentInstanceError.cannotDetachFromOwnPrivateTimeline(timelineId)
        }

        timeline.attachedAgentInstanceId = nil
        timeline.updatedAt = Date()
        try await timelineStore.saveTimeline(timeline)

        // Log to agent's private timeline if it still exists
        if let agent = try? await instanceStore.fetchAgentInstance(id: agentId) {
            let logMsg = ConversationMessage(
                timelineId: agent.privateTimelineId,
                role: .system,
                content: "[DETACH] Agent '\(agent.name)' detached from timeline "
                    + "\"\(timeline.title)\" (\(timelineId.uuidString.prefix(8)))"
            )
            try? await messageStore.saveMessage(logMsg)
            logger.info("Agent '\(agent.name)' detached from timeline '\(timeline.title)'")
        }
    }

    // MARK: - Queries

    public func getInstance(id: UUID) async throws -> AgentInstance? {
        try await instanceStore.fetchAgentInstance(id: id)
    }

    public func listInstances() async throws -> [AgentInstance] {
        try await instanceStore.fetchAllAgentInstances()
    }

    public func getTimelines(attachedTo agentId: UUID) async throws -> [Timeline] {
        try await instanceStore.fetchTimelines(attachedToAgent: agentId)
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

        let allAttached = try await instanceStore.fetchTimelines(attachedToAgent: id)
        // Exclude the agent's own private timeline from the "still attached" check
        let nonPrivateAttached = allAttached.filter { $0.id != instance.privateTimelineId }

        if !nonPrivateAttached.isEmpty, !force {
            throw AgentInstanceError.hasAttachedTimelines(count: nonPrivateAttached.count)
        }

        // Force-detach from non-private timelines
        for var timeline in nonPrivateAttached {
            timeline.attachedAgentInstanceId = nil
            timeline.updatedAt = Date()
            try await timelineStore.saveTimeline(timeline)
        }

        // 1. Delete primary workspace directory (high risk IO)
        if let workspaceId = instance.primaryWorkspaceId {
            do {
                try await repository.deleteWorkspace(id: workspaceId, deleteDirectory: true)
            } catch {
                logger.error("Failed to delete workspace directory for agent \(id): \(error)")
            }
        }

        // 2. Delete private timeline
        try? await timelineStore.deleteTimeline(id: instance.privateTimelineId)

        // 3. Delete database record
        try await instanceStore.deleteAgentInstance(id: id)
        logger.info("Deleted agent instance \(id)")
    }
}
