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

/// Agent lifecycle entry points exposed by ``PositronicKit``.
public struct AgentCapability: Sendable {
    private let kit: PositronicKit

    init(kit: PositronicKit) {
        self.kit = kit
    }

    public func create(
        name: String,
        description: String,
        template: AgentTemplate? = nil
    ) async throws -> Agent {
        try await kit.agentManager.createAgent(
            from: template,
            name: name,
            description: description
        )
    }

    public func get(_ agentID: UUID) async throws -> Agent? {
        try await kit.agentManager.getAgent(id: agentID)
    }

    /// Updates an Agent's durable identity fields. The next admitted managed Turn observes
    /// the change; an already-admitted Turn keeps its captured context.
    public func update(_ agent: Agent) async throws {
        try await kit.agentManager.updateAgent(agent)
    }

    public func list() async throws -> [Agent] {
        try await kit.agentManager.listAgents()
    }

    public func attach(_ agentID: UUID, to threadID: UUID) async throws {
        try await kit.agentManager.attach(agentID: agentID, to: threadID)
    }

    public func detach(_ agentID: UUID, from threadID: UUID) async throws {
        try await kit.agentManager.detach(agentID: agentID, from: threadID)
    }

    public func threads(attachedTo agentID: UUID) async throws -> [Thread] {
        try await kit.agentManager.getThreads(attachedTo: agentID)
    }

    /// Begins the drain-to-retired lifecycle. Admitted Turns finish before ordinary
    /// attachments are detached and the primary Thread is archived.
    public func retire(_ agentID: UUID) async throws {
        try await kit.agentManager.retireAgent(id: agentID)
    }

    /// Permanently removes a retired Agent and its owned primary resources.
    public func purge(_ agentID: UUID) async throws {
        try await kit.agentManager.purgeAgent(id: agentID)
    }
}

/// Workspace catalog entry points exposed by ``PositronicKit``.
public struct WorkspaceCapability: Sendable {
    private let kit: PositronicKit

    init(kit: PositronicKit) {
        self.kit = kit
    }

    public func create(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originID: UUID? = nil,
        rootPath: String? = nil
    ) async throws -> WorkspaceReference {
        try await kit.workspaceCatalog.createWorkspace(
            uri: uri,
            location: location,
            originID: originID,
            rootPath: rootPath
        )
    }

    public func get(_ workspaceID: UUID, includeTools: Bool = true) async throws -> WorkspaceReference? {
        try await kit.workspaceCatalog.getWorkspace(id: workspaceID, includeTools: includeTools)
    }

    public func list() async throws -> [WorkspaceReference] {
        try await kit.workspaceCatalog.listWorkspaces()
    }

    public func update(_ workspace: WorkspaceReference) async throws {
        try await kit.workspaceCatalog.updateWorkspace(workspace)
    }

    public func delete(_ workspaceID: UUID, deleteDirectory: Bool = false) async throws {
        try await kit.workspaceCatalog.deleteWorkspace(
            id: workspaceID,
            deleteDirectory: deleteDirectory
        )
    }
}

/// Raw, Thread-free model inference entry points exposed by ``PositronicKit``.
public struct ModelInferenceCapability: Sendable {
    private let kit: PositronicKit

    init(kit: PositronicKit) {
        self.kit = kit
    }

    public var isConfigured: Bool {
        get async { await kit.isLanguageModelConfigured }
    }

    public func generate(
        _ prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval = 60
    ) async throws -> OneShotResult {
        try await kit.completeResult(
            prompt,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )
    }

    public func stream(
        _ prompt: String,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval = 60
    ) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        kit.stream(
            prompt,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )
    }

    public func generateStructured(
        _ prompt: String,
        structuredOutput: StructuredOutputRequest,
        generationParameters: GenerationParameters? = nil,
        idleTimeout: TimeInterval = 60
    ) async throws -> String {
        try await kit.complete(
            prompt,
            structuredOutput: structuredOutput,
            generationParameters: generationParameters,
            idleTimeout: idleTimeout
        )
    }
}
