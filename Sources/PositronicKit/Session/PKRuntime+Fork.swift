import Foundation
import PKContracts

public extension PKRuntime {
    /// Clones a Timeline's session into a detached, ephemeral fork.
    ///
    /// The fork copies the source Timeline's durable history into a fresh in-memory runtime that
    /// shares this runtime's language model, Agent store, and Workspace stores. The fork owns a
    /// separate repository and prompt-journal state, so writing to the fork never touches the
    /// source Timeline or its Turn ledger.
    ///
    /// The fork runs direct Turns and has read-only tool access: the default filesystem tools and
    /// the Timeline observation tools, with the Timeline-send tool absent (a fork has no attached
    /// Agent). Dropping the returned ``TimelineFork`` releases its runtime.
    ///
    /// - Parameters:
    ///   - timelineID: The source Timeline to clone.
    ///   - context: The explicit direct-Turn authority the fork's Turns run with.
    /// - Returns: A fork handle owning the cloned session.
    /// - Throws: ``TimelineError/timelineNotFound`` when no Timeline has `timelineID`.
    func fork(
        from timelineID: UUID,
        context: DirectTurnContext
    ) async throws -> TimelineFork {
        guard let source = try await timelineManager.timelineStore.fetchTimeline(id: timelineID) else {
            throw TimelineError.timelineNotFound
        }
        let sourceMessages = try await runtimeRepository.fetchMessages(for: timelineID)

        var forkDependencies = dependencies
        forkDependencies.runtimeRepository = InMemoryTimelineRuntimeRepository()
        // The fork owns its prompt-journal state; it must not perturb the source's.
        forkDependencies.sharedRegistry = TimelinePromptJournals()
        forkDependencies.agentAuthorityCoordinator = nil
        // A fork is direct and read-only. The default filesystem tool set is already read-only
        // (change directory, list, find, search, read); the Timeline-send tool requires an
        // attached Agent, which a fork does not have.
        forkDependencies.runtimeToolPolicy = RuntimeToolPolicy(
            installFilesystemTools: true,
            installTimelineObservationTools: true,
            installsTimelineSendTool: false
        )
        let forkRuntime = PKRuntime(dependencies: forkDependencies)

        let forkTimelineID = UUID()
        var forkRecord = source
        forkRecord.id = forkTimelineID
        forkRecord.attachedAgentID = nil
        forkRecord.isPrivate = true
        forkRecord.isArchived = false
        forkRecord.title = "Fork of \(source.title)"

        let forkRepository = forkDependencies.runtimeRepository
        try await forkRepository.saveTimeline(forkRecord)
        for message in sourceMessages {
            var clone = message
            clone.timelineID = forkTimelineID
            try await forkRepository.saveMessage(clone)
        }

        // Direct Turns take their tools only from `TurnOptions.tools`, so the fork must read its
        // own read-only tool set from the fork runtime's registry and inject it on every Turn.
        // Hydration installs the set from the fork's read-only `RuntimeToolPolicy`.
        try await forkRuntime.timelineManager.ensureTimelineExists(id: forkTimelineID)
        let forkTools = await forkRuntime.timelineManager.enabledTools(for: forkTimelineID)

        return TimelineFork(
            timelineID: forkTimelineID,
            runtime: forkRuntime,
            context: context,
            tools: forkTools
        )
    }
}
