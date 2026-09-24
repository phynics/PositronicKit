import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

/// Manages the lifecycle of agents: creation, attachment to timelines,
/// detachment, and deletion.
///
/// Attachment rules:
/// - Each timeline can have at most one attached agent (exclusive lock).
/// - One agent can attach to multiple timelines simultaneously.
/// - `attach` is idempotent: re-attaching the same agent to the same timeline is a no-op.
/// - If `attachedAgentId` references a deleted agent, it is nulled on access.
actor AgentManager {
    public struct Stores: Sendable {
        public let agentStore: any AgentStoreProtocol
        public let timelineStore: any TimelinePersistenceProtocol
        public let messageStore: any TimelineMessageStoreProtocol
        public let workspaceStore: any WorkspaceStore
        public let runtimeRepository: any TimelineRuntimeRepository?
        public let timelineAuthorityCoordinator: TimelineAuthorityCoordinator?
        public let agentAuthorityCoordinator: AgentAuthorityCoordinator?
        /// The process-local Turn terminal signal. When supplied, `waitForIdle` wakes as soon as
        /// the hub observes a timeline's active Turn finish instead of relying solely on its
        /// bounded fallback poll. `nil` (the default) makes every wait use that fallback poll.
        let eventHub: TurnEventHub?

        public init(
            agentStore: any AgentStoreProtocol,
            timelineStore: any TimelinePersistenceProtocol,
            messageStore: any TimelineMessageStoreProtocol,
            workspaceStore: any WorkspaceStore,
            runtimeRepository: any TimelineRuntimeRepository? = nil,
            timelineAuthorityCoordinator: TimelineAuthorityCoordinator? = nil,
            agentAuthorityCoordinator: AgentAuthorityCoordinator? = nil,
            eventHub: TurnEventHub? = nil
        ) {
            self.agentStore = agentStore
            self.timelineStore = timelineStore
            self.messageStore = messageStore
            self.workspaceStore = workspaceStore
            self.runtimeRepository = runtimeRepository
            self.timelineAuthorityCoordinator = timelineAuthorityCoordinator
            self.agentAuthorityCoordinator = agentAuthorityCoordinator
            self.eventHub = eventHub
        }

    }

    // Package-internal for assembly tests; consumers use the facade capabilities instead.
    let agentStore: any AgentStoreProtocol
    let timelineStore: any TimelinePersistenceProtocol
    let messageStore: any TimelineMessageStoreProtocol
    let workspaceStore: any WorkspaceStore
    let runtimeRepository: any TimelineRuntimeRepository?
    let timelineAuthorityCoordinator: TimelineAuthorityCoordinator
    let agentAuthorityCoordinator: AgentAuthorityCoordinator
    let eventHub: TurnEventHub?

    private let repository: any WorkspaceCatalog
    /// When non-nil, private-timeline deletion routes through `TimelineManager.evictTimelineFromMemory(id:)`
    /// so the in-memory caches and prompt-history registry entry are evicted alongside persistence,
    /// not just the persisted row (PKR-3).
    private let timelineManager: TimelineManager?
    private let logger = Logger.module(named: "agent-manager")

    public init(
        repository: any WorkspaceCatalog,
        stores: Stores,
        timelineManager: TimelineManager? = nil
    ) {
        self.repository = repository
        self.agentStore = stores.agentStore
        self.timelineStore = stores.timelineStore
        self.messageStore = stores.messageStore
        self.workspaceStore = stores.workspaceStore
        self.runtimeRepository = stores.runtimeRepository
        self.timelineAuthorityCoordinator = stores.timelineAuthorityCoordinator
            ?? timelineManager?.timelineAuthorityCoordinator
            ?? TimelineAuthorityCoordinator()
        self.agentAuthorityCoordinator = stores.agentAuthorityCoordinator ?? AgentAuthorityCoordinator()
        self.eventHub = stores.eventHub
        self.timelineManager = timelineManager
    }

    public init(repository: any WorkspaceCatalog) {
        self.init(
            repository: repository,
            stores: .init(
                agentStore: InMemoryAgentStore(),
                timelineStore: InMemoryTimelinePersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: InMemoryWorkspacePersistence()
            )
        )
    }

    // MARK: - Create

    /// Creates a new agent, its private workspace, and its private timeline atomically.
    /// If a later write fails, completed (and attempted) writes are compensated in reverse order;
    /// cleanup failures are logged while the original creation error is rethrown.
    /// - Parameters:
    ///   - template: Optional `AgentTemplate` template to seed workspace files from.
    ///   - name: Display name for the agent.
    ///   - description: Purpose description.
    /// - Returns: The created `Agent`.
    public func createAgent(
        from template: AgentTemplate? = nil,
        name: String,
        description: String
    ) async throws -> Agent {
        try validate(name: name, description: description)

        let agentId = UUID()
        let privateTimelineID = UUID()

        var workspace: WorkspaceReference?
        var didAttemptTimelineSave = false
        var didAttemptAgentSave = false
        var didAttemptAuditSave = false

        do {
            // 1. Create workspace via repository
            let createdWorkspace = try await repository.createAgentWorkspace(
                agentID: agentId,
                template: template
            )
            workspace = createdWorkspace

            // 2. Persist private timeline
            let privateTimeline = TimelineRecord(
                id: privateTimelineID,
                title: "[\(name)] Private",
                // An Agent's primary workspace is owned by the Agent record, not by an
                // ordinary Timeline binding.
                attachedAgentID: agentId,
                isPrivate: true
            )
            didAttemptTimelineSave = true
            try await timelineStore.saveTimeline(privateTimeline)

            // 3. Persist agent
            let agent = Agent(
                id: agentId,
                name: name,
                description: description,
                primaryWorkspaceID: createdWorkspace.id,
                privateTimelineID: privateTimelineID
            )
            didAttemptAgentSave = true
            try await agentStore.saveAgent(agent)

            // 4. Log creation to private timeline
            let creationMsg = TimelineMessage(
                timelineID: privateTimelineID,
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
                privateTimelineID: privateTimelineID,
                workspace: workspace,
                didAttemptTimelineSave: didAttemptTimelineSave,
                didAttemptAgentSave: didAttemptAgentSave,
                didAttemptAuditSave: didAttemptAuditSave,
                originalError: error
            )
            throw error
        }
    }

    // MARK: - Attach / Detach

    /// Creates an ordinary Timeline already attached to an active Agent.
    ///
    /// Agent lifecycle changes are serialized for the full operation. Timeline creation owns its
    /// own durable rollback, so a workspace or persistence failure cannot leave the new Timeline
    /// or its attachment behind.
    func createTimeline(title: String, attaching agentID: UUID) async throws -> TimelineRecord {
        guard let timelineManager else {
            throw TimelineError.unavailable
        }

        return try await agentAuthorityCoordinator.withAgent(agentID) { [self, timelineManager] in
            guard let agent = try await agentStore.fetchAgent(id: agentID) else {
                throw AgentError.agentNotFound(agentID)
            }
            try agent.requireActive()

            let timeline = try await timelineManager.createTimeline(
                title: title,
                attachedAgentID: agentID
            )
            await recordAttachment(agent: agent, to: timeline)
            return timeline
        }
    }

    /// Attaches an agent to a timeline.
    ///
    /// - Idempotent: no-op if the same agent is already attached.
    /// - Fails if a different agent is attached (caller must detach it first).
    /// - If `attachedAgentId` references a non-existent agent, it is cleared automatically.
    public func attach(agentID: UUID, to timelineID: UUID) async throws {
        try await agentAuthorityCoordinator.withAgent(agentID) { [self] in
            try await attachUnlocked(agentID: agentID, to: timelineID)
        }
    }

    private func attachUnlocked(agentID: UUID, to timelineID: UUID) async throws {
        // Agent lifecycle is serialized by the caller's agent lane. Resolve it before entering
        // the Timeline lane, then resolve the Timeline itself inside that lane. In particular, do
        // not carry a pre-lane Timeline snapshot into the mutation: another attachment may commit
        // while this operation is waiting for the per-Timeline authority coordinator.
        guard let agent = try await agentStore.fetchAgent(id: agentID) else {
            throw AgentError.agentNotFound(agentID)
        }
        try agent.requireActive()

        let result: (timeline: TimelineRecord, didAttach: Bool) = try await timelineAuthorityCoordinator.withTimeline(timelineID) { [self] in
            try await self.requireExecutionContextMutable(for: timelineID)
            guard let timeline = try await self.timelineStore.fetchTimeline(id: timelineID) else {
                throw TimelineError.timelineNotFound
            }

            // Idempotent
            if timeline.attachedAgentID == agentID {
                return (timeline: timeline, didAttach: false)
            }

            // Prevent attaching an agent to a private timeline owned by another agent
            if timeline.isPrivate {
                if let currentOwner = timeline.attachedAgentID, currentOwner != agentID {
                    throw AgentError.cannotAttachToPrivateTimeline(timelineID)
                }
            }

            // Check for existing attachment while holding the same lane as the mutation. This
            // makes the conflict decision authoritative when two agents attach concurrently.
            if let existingId = timeline.attachedAgentID {
                if try await self.agentStore.fetchAgent(id: existingId) != nil {
                    throw AgentError.differentAgentAlreadyAttached(existingId)
                }
                // Dangling reference — clear it with a warning
                self.logger.warning(
                    "Clearing dangling agent reference \(existingId) on timeline \(timelineID)")
            }

            var updated = timeline
            updated.attachedAgentID = agentID
            updated.updatedAt = Date()
            try await self.timelineStore.saveTimeline(updated)
            return (timeline: updated, didAttach: true)
        }
        guard result.didAttach else { return }
        await timelineManager?.replaceCachedTimelineIfPresent(result.timeline)
        let timeline = result.timeline

        await recordAttachment(agent: agent, to: timeline)
    }

    private func recordAttachment(agent: Agent, to timeline: TimelineRecord) async {
        let logMsg = TimelineMessage(
            timelineID: agent.privateTimelineID,
            role: .system,
            content: "[ATTACH] Agent '\(agent.name)' (\(agent.id.uuidString.prefix(8))) "
                + "attached to timeline \"\(timeline.title)\" (\(timeline.id.uuidString.prefix(8)))"
        )
        do {
            try await messageStore.saveMessage(logMsg)
        } catch {
            logger.warning(
                "Failed to persist attach audit log for agent \(agent.id) on timeline \(timeline.id) (private timeline \(agent.privateTimelineID)): \(ErrorKit.userFriendlyMessage(for: error))")
        }

        logger.info("Agent '\(agent.name)' attached to timeline '\(timeline.title)'")
    }

    /// Detaches an agent from a timeline.
    /// No-op if the agent is not attached to that timeline.
    public func detach(agentID: UUID, from timelineID: UUID) async throws {
        try await agentAuthorityCoordinator.withAgent(agentID) { [self] in
            try await detachUnlocked(agentID: agentID, from: timelineID)
        }
    }

    private func detachUnlocked(agentID: UUID, from timelineID: UUID) async throws {
        try await requireExecutionContextMutable(for: timelineID)
        guard let timeline = try await timelineStore.fetchTimeline(id: timelineID) else {
            throw TimelineError.timelineNotFound
        }

        guard timeline.attachedAgentID == agentID else { return }

        // Prevent detaching an agent from its own private timeline
        if timeline.isPrivate, timeline.attachedAgentID == agentID {
            throw AgentError.cannotDetachFromOwnPrivateTimeline(timelineID)
        }

        let originalTimeline = timeline
        let updatedTimeline = try await timelineAuthorityCoordinator.withTimeline(timelineID) { [self, originalTimeline] in
            try await self.requireExecutionContextMutable(for: timelineID)
            var updated = originalTimeline
            updated.attachedAgentID = nil
            updated.updatedAt = Date()
            try await self.timelineStore.saveTimeline(updated)
            return updated
        }
        await timelineManager?.replaceCachedTimelineIfPresent(updatedTimeline)

        // Log to agent's private timeline if it still exists
        if let agent = try? await agentStore.fetchAgent(id: agentID) {
            let logMsg = TimelineMessage(
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

    // MARK: - Queries

    public func agent(id: UUID) async throws -> Agent? {
        try await agentStore.fetchAgent(id: id)
    }

    public func listAgents() async throws -> [Agent] {
        try await agentStore.fetchAllAgents()
    }

    public func timelines(attachedTo agentID: UUID) async throws -> [TimelineRecord] {
        try await fetchAttachedTimelines(for: agentID)
    }

    public func updateAgent(_ agent: Agent) async throws {
        try validate(name: agent.name, description: agent.description)
        try await agentAuthorityCoordinator.withAgent(agent.id) { [self] in
            guard let current = try await agentStore.fetchAgent(id: agent.id) else {
                throw AgentError.agentNotFound(agent.id)
            }
            try current.requireActive()
            var updated = current
            updated.name = agent.name
            updated.description = agent.description
            updated.updatedAt = Date()
            try await agentStore.saveAgent(updated)
        }
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
        privateTimelineID: UUID,
        workspace: WorkspaceReference?,
        didAttemptTimelineSave: Bool,
        didAttemptAgentSave: Bool,
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

        if didAttemptTimelineSave {
            do {
                try await timelineStore.deleteTimeline(id: privateTimelineID)
            } catch {
                logCreateRollbackFailure(
                    operation: "deleteTimeline",
                    entityID: privateTimelineID,
                    agentID: agentID,
                    originalError: originalError,
                    cleanupError: error
                )
            }
        }

        if let workspace {
            do {
                try await repository.deleteWorkspace(id: workspace.id, includingDirectory: true)
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

    private func fetchAttachedTimelines(for agentID: UUID) async throws -> [TimelineRecord] {
        let allTimelines = try await timelineStore.fetchAllTimelines(includeArchived: true)
        return allTimelines.filter { $0.attachedAgentID == agentID }
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

    private func requireExecutionContextMutable(for timelineID: UUID) async throws {
        if let timelineManager {
            try await timelineManager.requireExecutionContextMutable(for: timelineID)
        } else if let runtimeRepository,
                  let activeTurn = try await runtimeRepository.fetchActiveTurn(for: timelineID)
        {
            throw TimelineRuntimeRepositoryError.timelineBusy(
                timelineID: timelineID,
                activeTurnID: activeTurn.identity.turnID
            )
        }
    }

    // MARK: - Retirement / Purge

    /// Drains an Agent without interrupting Turns already admitted against it.
    public func retireAgent(id: UUID) async throws {
        try await agentAuthorityCoordinator.withAgent(id) { [self] in
            try await retireAgentUnlocked(id: id)
        }
    }

    private func retireAgentUnlocked(id: UUID) async throws {
        guard let agent = try await agentStore.fetchAgent(id: id) else {
            throw AgentError.agentNotFound(id)
        }
        guard agent.lifecycle != .retired else { return }

        var retiring = agent
        retiring.lifecycle = .retiring
        retiring.updatedAt = Date()
        try await agentStore.saveAgent(retiring)

        let attachedTimelines = try await fetchAttachedTimelines(for: id)
            .filter { $0.id != agent.privateTimelineID }
        for timeline in attachedTimelines {
            try await waitForIdle(timelineID: timeline.id)
            try await detachUnlocked(agentID: id, from: timeline.id)
        }

        // The private Timeline is not an ordinary attachment and therefore is not included in
        // the detachment list. Drain it explicitly before disabling its durable history.
        try await waitForIdle(timelineID: agent.privateTimelineID)

        var retired = retiring
        retired.lifecycle = .retired
        retired.updatedAt = Date()
        try await agentStore.saveAgent(retired)

        // The primary Timeline is an Agent-owned continuity boundary. Retiring disables new
        // managed activity by archiving it; its durable history remains available to purge
        // policy and historical attribution.
        if let primaryTimeline = try await timelineStore.fetchTimeline(id: agent.privateTimelineID) {
            var disabled = primaryTimeline
            disabled.isArchived = true
            disabled.updatedAt = Date()
            try await timelineStore.saveTimeline(disabled)
        }
    }

    /// Purges an Agent only after retirement has completed and no Turn remains active.
    public func purgeAgent(id: UUID) async throws {
        try await agentAuthorityCoordinator.withAgent(id) { [self] in
            try await purgeAgentUnlocked(id: id)
        }
    }

    private func purgeAgentUnlocked(id: UUID) async throws {
        guard let agent = try await agentStore.fetchAgent(id: id) else {
            throw AgentError.agentNotFound(id)
        }
        guard agent.lifecycle == .retired else {
            throw AgentError.agentNotRetired(id)
        }
        if let active = try await runtimeRepository?.fetchActiveTurn(for: agent.privateTimelineID) {
            throw TimelineRuntimeRepositoryError.timelineBusy(
                timelineID: agent.privateTimelineID,
                activeTurnID: active.identity.turnID
            )
        }
        let attached = try await fetchAttachedTimelines(for: id)
            .filter { $0.id != agent.privateTimelineID }
        guard attached.isEmpty else {
            throw AgentError.hasAttachedTimelines(count: attached.count)
        }
        try await deleteAgentUnlocked(id: id, force: true)
    }

    /// Waits until `timelineID` has no active Turn.
    ///
    /// Each loop iteration waits out exactly one active Turn: the hub wakes it immediately if
    /// this process admitted that Turn, or a single bounded poll covers one admitted elsewhere
    /// (including when no hub was wired into this manager at all). The outer loop then re-checks
    /// the repository, since a new Turn can in principle be admitted for the timeline between one
    /// Turn finishing and this call observing it idle.
    private func waitForIdle(timelineID: UUID) async throws {
        guard let runtimeRepository else { return }
        // A manager constructed without an event hub (e.g. in a unit test) still gets a correct,
        // bounded wait: an empty hub never tracks any turn as active, so `awaitResult` always
        // takes its single-poll fallback path with the same timeout policy.
        let waiter = TurnTerminationWaiter(hub: eventHub ?? TurnEventHub())
        while let activeTurn = try await runtimeRepository.fetchActiveTurn(for: timelineID) {
            try Task.checkCancellation()
            let turnID = activeTurn.identity.turnID
            let observation = try await waiter.awaitResult(turnID: turnID) {
                let refreshed = try await runtimeRepository.fetchTurn(id: turnID)
                return (refreshed == nil || refreshed?.isTerminal == true) ? true : nil
            }
            if case .timedOut = observation {
                throw AgentError.turnStillActive(turnID: turnID)
            }
        }
    }

    // MARK: - Delete

    /// Deletes an agent and optionally force-detaches it from all timelines.
    /// - Parameters:
    ///   - id: The agent identifier to delete.
    ///   - force: If false, throws if the agent is still attached to any timelines.
    public func deleteAgent(id: UUID, force: Bool) async throws {
        try await agentAuthorityCoordinator.withAgent(id) { [self] in
            try await deleteAgentUnlocked(id: id, force: force)
        }
    }

    private func deleteAgentUnlocked(id: UUID, force: Bool) async throws {
        guard let agent = try await agentStore.fetchAgent(id: id) else {
            throw AgentError.agentNotFound(id)
        }

        let allAttached = try await fetchAttachedTimelines(for: id)
        // Exclude the agent's own private timeline from the "still attached" check
        let nonPrivateAttached = allAttached.filter { $0.id != agent.privateTimelineID }

        if !nonPrivateAttached.isEmpty, !force {
            throw AgentError.hasAttachedTimelines(count: nonPrivateAttached.count)
        }

        // Force-detach from non-private timelines
        for timeline in nonPrivateAttached {
            let originalTimeline = timeline
            let updatedTimeline = try await timelineAuthorityCoordinator.withTimeline(timeline.id) { [self, originalTimeline] in
                try await self.requireExecutionContextMutable(for: originalTimeline.id)
                var updated = originalTimeline
                updated.attachedAgentID = nil
                updated.updatedAt = Date()
                try await self.timelineStore.saveTimeline(updated)
                return updated
            }
            await timelineManager?.replaceCachedTimelineIfPresent(updatedTimeline)
        }

        // Delete the private timeline before the workspace or agent record. If this fails,
        // preserve the agent and its workspace so the operation can be retried without
        // leaving a persisted timeline pointing at a removed agent.
        do {
            try await timelineStore.deleteTimeline(id: agent.privateTimelineID)
        } catch {
            logger.error(
                "Failed to delete private timeline \(agent.privateTimelineID) for agent \(id): \(ErrorKit.userFriendlyMessage(for: error))")
            throw error
        }

        // Evict the in-memory caches + prompt-history registry via the TimelineManager seam
        // when available (PKR-3), after the persisted row has been deleted successfully.
        if let timelineManager {
            await timelineManager.evictTimelineFromMemory(id: agent.privateTimelineID)
        }

        // Delete primary workspace directory (high risk IO)
        if let workspaceId = agent.primaryWorkspaceID {
            do {
                try await repository.deleteWorkspace(id: workspaceId, includingDirectory: true)
            } catch {
                logger.error("Failed to delete workspace directory for agent \(id): \(error)")
            }
        }

        // Delete database record
        try await agentStore.deleteAgent(id: id)
        logger.info("Deleted agent \(id)")
    }
}
