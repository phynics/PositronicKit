import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared

/// Manages conversation timelines, their associated context, and tool execution environments.
///
/// The `TimelineManager` is responsible for the lifecycle of `Timeline` objects,
/// including their creation, hydration from persistence, and cleanup. It also coordinates
/// timeline-specific components like `ContextManager` and `TimelineToolManager`.
/// It owns runtime coordination policy for timelines, but concrete workspace behavior remains
/// behind `WorkspaceManager` / `WorkspaceCreating` / `WorkspaceProtocol` so hosts can supply
/// local or remote workspace implementations without changing core orchestration.
public actor TimelineManager {
    public struct Stores: Sendable {
        public let timelineStore: any TimelinePersistenceProtocol
        public let messageStore: any MessageStoreProtocol
        public let workspaceStore: any WorkspacePersistenceProtocol
        public let toolPersistence: any ToolPersistenceProtocol

        public init(
            timelineStore: any TimelinePersistenceProtocol,
            messageStore: any MessageStoreProtocol,
            workspaceStore: any WorkspacePersistenceProtocol,
            toolPersistence: any ToolPersistenceProtocol
        ) {
            self.timelineStore = timelineStore
            self.messageStore = messageStore
            self.workspaceStore = workspaceStore
            self.toolPersistence = toolPersistence
        }
    }

    // MARK: - State

    /// In-memory cache of active timelines.
    var timelines: [UUID: Timeline] = [:]

    /// Context managers responsible for RAG and context gathering for each timeline.
    var contextManagers: [UUID: ContextManager] = [:]

    /// Tool managers handling tool registration and availability for each timeline.
    var toolManagers: [UUID: TimelineToolManager] = [:]

    /// Ongoing generation tasks for each timeline.
    var activeTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Dependencies

    let timelineStore: any TimelinePersistenceProtocol
    let messageStore: any MessageStoreProtocol
    let workspaceStore: any WorkspacePersistenceProtocol
    let toolPersistence: any ToolPersistenceProtocol

    let workspaceRoot: URL
    public let workspaceManager: any WorkspaceManagerProtocol
    let sectionProviders: [any PromptSectionProviding]

    // MARK: - Initialization

    public init(
        stores: Stores,
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = []
    ) {
        self.timelineStore = stores.timelineStore
        self.messageStore = stores.messageStore
        self.workspaceStore = stores.workspaceStore
        self.toolPersistence = stores.toolPersistence
        self.workspaceRoot = workspaceRoot
        self.sectionProviders = sectionProviders

        workspaceManager = WorkspaceManager(
            repository: AgentWorkspaceService(
                workspaceRoot: workspaceRoot,
                workspacePersistence: stores.workspaceStore
            ),
            workspaceCreator: workspaceCreator
        )
    }

    public init(
        workspaceRoot: URL,
        workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = []
    ) {
        self.init(
            stores: .init(
                timelineStore: InMemoryTimelinePersistence(),
                messageStore: InMemoryMessageStore(),
                workspaceStore: InMemoryWorkspacePersistence(),
                toolPersistence: InMemoryToolPersistence()
            ),
            workspaceRoot: workspaceRoot,
            workspaceCreator: workspaceCreator,
            sectionProviders: sectionProviders
        )
    }

    // MARK: - Prompt & Extension Support

    /// Gathers additional prompt sections from all registered `PromptSectionProviding` instances.
    public func gatherExtensionSections(
        timelineId: UUID,
        agentInstanceId: UUID?,
        message: String
    ) async -> [any Prompt] {
        let buildContext = PromptBuildContext(
            timelineId: timelineId,
            agentInstanceId: agentInstanceId,
            message: message
        )
        var sections: [any Prompt] = []
        for provider in sectionProviders {
            sections += await provider.sections(for: buildContext)
        }
        return sections
    }

    // MARK: - Component Management (Internal)

    /// Initializes and configures the internal components for a conversation timeline.
    func setupTimelineComponents(
        timeline: Timeline,
        workspaceURL: URL,
        parentId: UUID? = nil
    ) async {
        let contextWorkspace: (any WorkspaceProtocol)?
        if let firstId = timeline.attachedWorkspaceIds.first {
            contextWorkspace = try? await workspaceManager.getWorkspace(id: firstId)
        } else {
            contextWorkspace = nil
        }

        let contextManager = ContextManager(workspace: contextWorkspace)
        contextManagers[timeline.id] = contextManager

        let toolContextTimeline = ToolTimelineContext()

        let toolManager = await createToolManager(
            for: timeline, jailRoot: workspaceURL.path,
            toolContextTimeline: toolContextTimeline,
            parentId: parentId
        )
        toolManagers[timeline.id] = toolManager

        for attachedId in timeline.attachedWorkspaceIds {
            if let workspace = try? await workspaceManager.getWorkspace(id: attachedId) {
                await toolManager.registerWorkspace(workspace)
            }
        }
    }

    // MARK: - Task Management

    /// Registers a generation task for a timeline, cancelling any previous active task.
    public func registerTask(_ task: Task<Void, Never>, for timelineId: UUID) {
        activeTasks[timelineId]?.cancel()
        activeTasks[timelineId] = task
    }

    /// Explicitly cancels an ongoing generation task for a timeline.
    public func cancelGeneration(for timelineId: UUID) {
        activeTasks[timelineId]?.cancel()
        activeTasks.removeValue(forKey: timelineId)
    }
}

// MARK: - Lifecycle

public extension TimelineManager {
    /// Creates a new conversation timeline, initializes its workspace, and saves it to persistence.
    func createTimeline(title: String = "New Conversation") async throws -> Timeline {
        let timelineId = UUID()

        let timelineWorkspaceURL = workspaceRoot.appendingPathComponent(
            "timelines", isDirectory: true
        )
        .appendingPathComponent(timelineId.uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
            at: timelineWorkspaceURL, withIntermediateDirectories: true
        )

        try writeDefaultNotes(at: timelineWorkspaceURL)

        let workspace = WorkspaceReference(
            uri: .timelineWorkspace(timelineId),
            location: .runtime,
            rootPath: timelineWorkspaceURL.path,
            trustLevel: .full
        )

        try await workspaceStore.saveWorkspace(workspace)

        var timeline = Timeline(
            id: timelineId,
            title: title,
            attachedWorkspaceIds: [workspace.id]
        )
        timeline.workingDirectory = timelineWorkspaceURL.path

        timelines[timeline.id] = timeline
        await setupTimelineComponents(timeline: timeline, workspaceURL: timelineWorkspaceURL)
        try await timelineStore.saveTimeline(timeline)

        return timeline
    }

    /// Reconstructs a timeline and its components from persistence.
    func hydrateTimeline(id: UUID, parentId: UUID? = nil) async throws {
        if toolManagers[id] != nil { return }

        guard let timeline = try await timelineStore.fetchTimeline(id: id) else {
            throw TimelineError.timelineNotFound
        }

        let timelineWorkspaceURL: URL
        if let workingDir = timeline.workingDirectory {
            timelineWorkspaceURL = URL(fileURLWithPath: workingDir)
        } else {
            timelineWorkspaceURL = workspaceRoot.appendingPathComponent(
                "timelines", isDirectory: true
            ).appendingPathComponent(id.uuidString, isDirectory: true)
        }

        timelines[id] = timeline
        await setupTimelineComponents(
            timeline: timeline,
            workspaceURL: timelineWorkspaceURL,
            parentId: parentId
        )
    }

    /// Updates the title of a specific timeline.
    func updateTimelineTitle(id: UUID, title: String) async throws {
        var timeline: Timeline
        if let memoryTimeline = timelines[id] {
            timeline = memoryTimeline
        } else if let dbTimeline = try? await timelineStore.fetchTimeline(id: id) {
            timeline = dbTimeline
        } else {
            throw TimelineError.timelineNotFound
        }

        timeline.title = title
        timeline.updatedAt = Date()

        if timelines[id] != nil {
            timelines[id] = timeline
        }
        try await timelineStore.saveTimeline(timeline)
    }

    /// Removes a timeline and its components from memory.
    func deleteTimeline(id: UUID) {
        timelines.removeValue(forKey: id)
        contextManagers.removeValue(forKey: id)
        toolManagers.removeValue(forKey: id)
    }

    /// Removes active timelines from memory that have not been updated within the specified interval.
    func cleanupStaleTimelines(maxAge: TimeInterval) {
        let now = Date()
        let staleIds = timelines.values.filter { timeline in
            now.timeIntervalSince(timeline.updatedAt) > maxAge
        }.map { $0.id }

        for id in staleIds {
            deleteTimeline(id: id)
        }
    }

    // MARK: - Internal Helpers

    internal func writeDefaultNotes(at workspaceURL: URL) throws {
        let notesDir = workspaceURL.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        let welcomeNote = """
        # Welcome to Your PositronicKit Timeline

        This timeline is your private workspace. You can use the `Notes/` directory \
        in the Primary Workspace to store information that should persist and influence \
        your behavior across turns.

        ## System Orientation
        - Primary Workspace: Your runtime-managed sandbox.
        - Attached Workspaces: Directories mapped during this timeline.
        - Context Depth: Use `create_memory` for long-term facts and `Notes/` for project-specific guidance.
        """
        try welcomeNote.write(
            to: notesDir.appendingPathComponent("Welcome.md"),
            atomically: true, encoding: .utf8
        )

        let projectNote = """
        # Project Goals & Progress

        Use this note to track the active objective and your current progress.

        ## Active Objective
        [Describe what the user wants to achieve here]

        ## Key Milestones
        - [ ] Milestone 1
        - [ ] Milestone 2

        ## Decisions & Context
        Record any critical decisions made during the timeline here.
        """
        try projectNote.write(
            to: notesDir.appendingPathComponent("Project.md"),
            atomically: true, encoding: .utf8
        )
    }
}

// MARK: - Queries & Agent Support

public extension TimelineManager {
    /// Retrieves a timeline by its ID and updates its `updatedAt` timestamp.
    func getTimeline(id: UUID) -> Timeline? {
        guard var timeline = timelines[id] else { return nil }
        timeline.updatedAt = Date()
        timelines[id] = timeline
        return timeline
    }

    /// Retrieves the tool manager for a timeline if it is active.
    func getToolManager(for timelineId: UUID) -> TimelineToolManager? {
        return toolManagers[timelineId]
    }

    /// Fetches the message history for a specific timeline from persistence.
    func getHistory(for timelineId: UUID) async throws -> [Message] {
        let conversationMessages = try await messageStore.fetchMessages(for: timelineId)
        return conversationMessages.map { $0.toMessage() }
    }

    /// Lists all active (non-archived) timelines from persistence.
    func listTimelines() async throws -> [Timeline] {
        return try await timelineStore.fetchAllTimelines(includeArchived: false)
    }

}

// MARK: - Tool Management

public extension TimelineManager {
    // swiftlint:disable:next function_parameter_count
    internal func createToolManager(
        for session: Timeline,
        jailRoot: String,
        toolContextTimeline: ToolTimelineContext,
        parentId _: UUID? = nil,
        remoteDepth: Int = 0
    ) async -> TimelineToolManager {
        let currentWD = session.workingDirectory ?? jailRoot

        // V1 runtime policy: these filesystem and timeline observation tools are installed by
        // default for every timeline-managed session. Timeline send is additionally installed when
        // an attached agent identity is available, because it requires a sender identity.
        var availableTools: [AnyTool] = [
            // Filesystem Tools
            AnyTool(ChangeDirectoryTool(
                currentPath: currentWD,
                root: jailRoot,
                onChange: { _ in
                    // Update working directory logic
                }
            )),
            AnyTool(ListDirectoryTool(currentDirectory: currentWD, jailRoot: jailRoot)),
            AnyTool(FindFileTool(currentDirectory: currentWD, jailRoot: jailRoot)),
            AnyTool(SearchFileContentTool(currentDirectory: currentWD, jailRoot: jailRoot)),
            AnyTool(SearchFilesTool(currentDirectory: currentWD, jailRoot: jailRoot)),
            AnyTool(ReadFileTool(currentDirectory: currentWD, jailRoot: jailRoot)),

            // Timeline Observation Tools (always available)
            AnyTool(TimelineListTool(timelineStore: timelineStore)),
            AnyTool(TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore))
        ]

        // Timeline Send: only available when an agent is attached (needs sender identity)
        if let agentId = session.attachedAgentInstanceId {
            availableTools.append(AnyTool(TimelineSendTool(
                messageStore: messageStore,
                timelineStore: timelineStore,
                agentInstanceId: agentId,
                currentRemoteDepth: remoteDepth
            )))
        }

        return TimelineToolManager(
            availableTools: availableTools, timelineContext: toolContextTimeline
        )
    }

    func findWorkspaceForTool(_ tool: ToolReference, in workspaceIds: [UUID]) async throws
        -> UUID? {
        return try await toolPersistence.findWorkspaceId(forToolId: tool.toolId, in: workspaceIds)
    }

    func getToolSource(toolId: String, for timelineId: UUID) async -> String? {
        guard let timeline = timelines[timelineId] else { return nil }

        if let toolManager = toolManagers[timelineId] {
            let systemTools = await toolManager.getAvailableTools()
            if systemTools.contains(where: { $0.id == toolId }) {
                return "System"
            }
        }

        return try? await toolPersistence.fetchToolSource(
            toolId: toolId,
            workspaceIds: timeline.attachedWorkspaceIds,
            primaryWorkspaceId: nil
        )
    }
}

// MARK: - Workspace Management

public extension TimelineManager {
    func attachWorkspace(_ workspaceId: UUID, to timelineId: UUID) async throws {
        var timeline: Timeline

        if let memoryTimeline = timelines[timelineId] {
            timeline = memoryTimeline
        } else if let dbTimeline = try await timelineStore.fetchTimeline(id: timelineId) {
            timeline = dbTimeline
        } else {
            throw TimelineError.timelineNotFound
        }

        if !timeline.attachedWorkspaceIds.contains(workspaceId) {
            timeline.attachedWorkspaceIds.append(workspaceId)
        }

        timeline.updatedAt = Date()

        if timelines[timelineId] != nil {
            timelines[timelineId] = timeline
        }
        try await timelineStore.saveTimeline(timeline)

        if let toolManager = toolManagers[timelineId] {
            if let workspace = try? await workspaceManager.getWorkspace(id: workspaceId) {
                await toolManager.registerWorkspace(workspace)
            }
        }
    }

    func detachWorkspace(_ workspaceId: UUID, from timelineId: UUID) async throws {
        var timeline: Timeline

        if let memoryTimeline = timelines[timelineId] {
            timeline = memoryTimeline
        } else if let dbTimeline = try await timelineStore.fetchTimeline(id: timelineId) {
            timeline = dbTimeline
        } else {
            throw TimelineError.timelineNotFound
        }

        timeline.attachedWorkspaceIds.removeAll { $0 == workspaceId }
        timeline.updatedAt = Date()

        if timelines[timelineId] != nil {
            timelines[timelineId] = timeline
        }

        try await timelineStore.saveTimeline(timeline)

        if let toolManager = toolManagers[timelineId] {
            await toolManager.unregisterWorkspace(workspaceId)
        }
    }

    func getWorkspaces(for timelineId: UUID) async -> (primary: WorkspaceReference?, attached: [WorkspaceReference])? {
        let attachedIds: [UUID]

        if let timeline = timelines[timelineId] {
            attachedIds = timeline.attachedWorkspaceIds
        } else if let timeline = try? await timelineStore.fetchTimeline(id: timelineId) {
            attachedIds = timeline.attachedWorkspaceIds
        } else {
            return nil
        }

        var primary: WorkspaceReference?
        var attached: [WorkspaceReference] = []
        for aid in attachedIds {
            if let workspace = try? await getWorkspace(aid) {
                let normalizedWorkspace = normalizeWorkspaceStatus(workspace)

                if primary == nil,
                   normalizedWorkspace.location == .runtime || normalizedWorkspace.location == .runtimeTimeline {
                    primary = normalizedWorkspace
                } else {
                    attached.append(normalizedWorkspace)
                }
            }
        }

        return (primary, attached)
    }

    private func normalizeWorkspaceStatus(_ workspace: WorkspaceReference) -> WorkspaceReference {
        var normalizedWorkspace = workspace
        if normalizedWorkspace.location == .runtime,
           let path = normalizedWorkspace.rootPath,
           !FileManager.default.fileExists(atPath: path) {
            normalizedWorkspace.status = .missing
        }
        return normalizedWorkspace
    }

    func getWorkspace(_ id: UUID) async throws -> WorkspaceReference? {
        return try await workspaceStore.fetchWorkspace(id: id, includeTools: true)
    }
}

// MARK: - Errors

public enum TimelineError: PKError {
    case timelineNotFound

    public var errorDomain: String { PKErrorDomain.timeline }

    public var errorCode: Int {
        switch self {
        case .timelineNotFound: return 6001
        }
    }

    public var userFriendlyMessage: String {
        switch self {
        case .timelineNotFound:
            return "The requested chat timeline could not be found."
        }
    }
}

// MARK: - Internal ContextManager Access

extension TimelineManager {
    /// Retrieves the context manager for a timeline if it is active.
    func getContextManager(for timelineId: UUID) -> ContextManager? {
        return contextManagers[timelineId]
    }
}
