import Dependencies
import ErrorKit
import Foundation
import Logging
import PKPrompt
import PKShared

/// Manages conversation timelines, their associated context, and tool execution environments.
///
/// The `TimelineManager` is responsible for the lifecycle of `Timeline` objects,
/// including their creation, hydration from persistence, and cleanup. It also coordinates
/// timeline-specific components like `ContextManager` and `ToolExecutor`.
public actor TimelineManager {
    // MARK: - State

    /// In-memory cache of active timelines.
    var timelines: [UUID: Timeline] = [:]

    /// Context managers responsible for RAG and context gathering for each timeline.
    var contextManagers: [UUID: ContextManager] = [:]

    /// Tool managers handling tool registration and availability for each timeline.
    var toolManagers: [UUID: TimelineToolManager] = [:]

    /// Tool executors that perform the actual tool calls for each timeline.
    var toolExecutors: [UUID: ToolExecutor] = [:]

    /// State management for tool execution context within a timeline.
    var toolContextTimelines: [UUID: ToolTimelineContext] = [:]

    /// Ongoing generation tasks for each timeline.
    var activeTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Dependencies

    @Dependency(\.timelinePersistence) var timelineStore
    @Dependency(\.messageStore) var messageStore
    @Dependency(\.workspacePersistence) var workspaceStore
    @Dependency(\.memoryStore) var memoryStore
    @Dependency(\.toolPersistence) var toolPersistence
    @Dependency(\.agentTemplateStore) var agentTemplateStore
    @Dependency(\.clientStore) var clientStore
    @Dependency(\.agentInstanceStore) var agentInstanceStore

    let vectorStore: (any VectorStoreProtocol)?
    let workspaceRoot: URL
    let connectionManager: (any ClientConnectionManagerProtocol)?
    public let workspaceManager: any WorkspaceManagerProtocol
    let sectionProviders: [any PromptSectionProviding]

    // MARK: - Initialization

    public init(
        vectorStore: (any VectorStoreProtocol)? = nil,
        workspaceRoot: URL,
        connectionManager: (any ClientConnectionManagerProtocol)? = nil,
        workspaceCreator: any WorkspaceCreating = NullWorkspaceCreator(),
        sectionProviders: [any PromptSectionProviding] = []
    ) {
        self.vectorStore = vectorStore
        self.workspaceRoot = workspaceRoot
        self.connectionManager = connectionManager
        self.sectionProviders = sectionProviders

        workspaceManager = WorkspaceManager(
            repository: AgentWorkspaceService(workspaceRoot: workspaceRoot),
            connectionManager: connectionManager,
            workspaceCreator: workspaceCreator
        )
    }

    // MARK: - Prompt & Extension Support

    /// Gathers additional prompt sections from all registered `PromptSectionProviding` instances.
    public func gatherExtensionSections(
        timelineId: UUID,
        agentInstanceId: UUID?,
        message: String
    ) async -> [any ContextSection] {
        let buildContext = PromptBuildContext(
            timelineId: timelineId,
            agentInstanceId: agentInstanceId,
            message: message
        )
        var sections: [any ContextSection] = []
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
        toolContextTimelines[timeline.id] = toolContextTimeline

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

        let toolExecutor = ToolExecutor(
            toolManager: toolManager,
            timelineContext: toolContextTimeline
        )
        toolExecutors[timeline.id] = toolExecutor
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
            hostType: .runtime,
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
        if toolExecutors[id] != nil { return }

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
        toolExecutors.removeValue(forKey: id)
        toolContextTimelines.removeValue(forKey: id)
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

    /// Retrieves the context manager for a timeline if it is active.
    func getContextManager(for timelineId: UUID) -> ContextManager? {
        return contextManagers[timelineId]
    }

    /// Retrieves the tool executor for a timeline if it is active.
    func getToolExecutor(for timelineId: UUID) -> ToolExecutor? {
        return toolExecutors[timelineId]
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

    // MARK: - Agent Support

    /// Returns the agent instance attached to a timeline, cleaning up dangling references.
    func getAttachedAgentInstance(for timelineId: UUID) async -> AgentInstance? {
        let agentId: UUID?
        if let cached = timelines[timelineId] {
            agentId = cached.attachedAgentInstanceId
        } else if let fetched = try? await timelineStore.fetchTimeline(id: timelineId) {
            agentId = fetched.attachedAgentInstanceId
        } else {
            return nil
        }

        guard let agentId else { return nil }

        if let agent = try? await agentInstanceStore.fetchAgentInstance(id: agentId) {
            return agent
        }

        // Dangling reference cleanup
        await cleanupDanglingAgentReference(timelineId: timelineId, agentId: agentId)
        return nil
    }

    /// Reads Notes/system.md from the attached agent's workspace, if any.
    func getAgentSystemInstructions(for timelineId: UUID) async -> String? {
        guard let agent = await getAttachedAgentInstance(for: timelineId),
              let workspaceId = agent.primaryWorkspaceId,
              let workspace = try? await workspaceStore.fetchWorkspace(id: workspaceId, includeTools: false),
              let rootPath = workspace.rootPath
        else { return nil }

        let systemMdPath = rootPath + "/Notes/system.md"
        return try? String(contentsOfFile: systemMdPath, encoding: .utf8)
    }

    // MARK: - Private Agent Helpers

    internal func cleanupDanglingAgentReference(timelineId: UUID, agentId: UUID) async {
        if var stale = try? await timelineStore.fetchTimeline(id: timelineId) {
            stale.attachedAgentInstanceId = nil
            try? await timelineStore.saveTimeline(stale)
            timelines[timelineId] = stale
            Logger.module(named: "timeline-manager").warning(
                "Cleared dangling agent \(agentId) reference on timeline \(timelineId)"
            )
        }
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
            AnyTool(TimelinePeekTool(messageStore: messageStore, timelineStore: timelineStore)),
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

    /// Returns the set of system tools available to any session, using the workspace root as a
    /// placeholder path. Intended for metadata queries (listing), not actual execution.
    func systemTools() async -> [AnyTool] {
        let jailRoot = workspaceRoot.path
        let dummyId = UUID()
        let toolTimelineContext = ToolTimelineContext()
        let dummyTimeline = Timeline(id: dummyId, workingDirectory: jailRoot)
        let manager = await createToolManager(
            for: dummyTimeline,
            jailRoot: jailRoot,
            toolContextTimeline: toolTimelineContext
        )
        return await manager.getAvailableTools()
    }

    func findWorkspaceForTool(_ tool: ToolReference, in workspaceIds: [UUID]) async throws
        -> UUID?
    {
        return try await toolPersistence.findWorkspaceId(forToolId: tool.toolId, in: workspaceIds)
    }

    func getAggregatedTools(for timelineId: UUID) async throws -> [ToolReference] {
        guard let timeline = timelines[timelineId] else { return [] }

        let workspaceIds = timeline.attachedWorkspaceIds
        guard !workspaceIds.isEmpty else { return [] }

        return try await toolPersistence.fetchTools(forWorkspaces: workspaceIds)
    }

    func getClientTools(clientId: UUID) async throws -> [ToolReference] {
        return try await clientStore.fetchClientTools(clientId: clientId)
    }

    /// Aggregates all available tool references for a session, including those from the client.
    func getAllToolReferences(timelineId: UUID, clientTools: [ToolReference]? = nil) async throws -> [ToolReference] {
        var references = try await getAggregatedTools(for: timelineId)

        if let clientTools = clientTools {
            references.append(contentsOf: clientTools)
        }

        // Deduplicate by ID
        var seenIds = Set<String>()
        return references.filter { ref in
            if seenIds.contains(ref.toolId) { return false }
            seenIds.insert(ref.toolId)
            return true
        }
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

        var attached: [WorkspaceReference] = []
        for aid in attachedIds {
            if var workspace = try? await getWorkspace(aid) {
                if workspace.hostType == .runtime, let path = workspace.rootPath {
                    if !FileManager.default.fileExists(atPath: path) {
                        workspace.status = .missing
                    }
                }
                attached.append(workspace)
            }
        }

        return (nil, attached)
    }

    func restoreWorkspace(_ id: UUID) async throws {
        guard let workspace = try await getWorkspace(id) else {
            throw TimelineError.timelineNotFound
        }

        if workspace.hostType == .runtime, let path = workspace.rootPath {
            let timelineWorkspaceURL = URL(fileURLWithPath: path)
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: path) {
                try fileManager.createDirectory(at: timelineWorkspaceURL, withIntermediateDirectories: true)

                if workspace.uri.host == "pk-runtime", workspace.uri.path.hasPrefix("/timelines/") {
                    let notesDir = timelineWorkspaceURL.appendingPathComponent("Notes", isDirectory: true)
                    try? fileManager.createDirectory(at: notesDir, withIntermediateDirectories: true)
                }
            }
        }
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
