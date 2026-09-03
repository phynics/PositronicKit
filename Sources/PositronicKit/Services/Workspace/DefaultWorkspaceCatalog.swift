import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

/// Manages the persistence and provisioning of agent private workspaces.
///
/// Handles workspace CRUD (delegating to `workspacePersistence`) and agent-specific
/// provisioning: creating sandboxed directories and seeding them from template files.
/// This is the default local/runtime provisioning service shipped with PositronicKit, not a
/// universal workspace model that hosts are required to adopt.
actor DefaultWorkspaceCatalog: WorkspaceCatalog {
    private let persistenceService: any WorkspaceStore
    private let bindingRepository: (any WorkspaceBindingRepository)?
    private let runtimeRepository: (any ThreadRuntimeRepository)?
    private let threadAuthorityCoordinator: ThreadAuthorityCoordinator?
    private let workspaceRoot: URL
    private let logger = Logger.module(named: "workspace-catalog")

    public init(
        workspaceRoot: URL,
        workspacePersistence: any WorkspaceStore,
        bindingRepository: (any WorkspaceBindingRepository)? = nil,
        runtimeRepository: (any ThreadRuntimeRepository)? = nil,
        threadAuthorityCoordinator: ThreadAuthorityCoordinator? = nil
    ) {
        persistenceService = workspacePersistence
        // The binding repository is resolved exactly once, by `PersistenceConfiguration`
        // (ADR 0004: binding authority is repository-only). This seam receives it rather than
        // inferring it from an `as?` downcast of `workspacePersistence` (C-02) — a caller that
        // wants binding-aware behavior (ownership checks before workspace deletion) must pass
        // one explicitly.
        self.bindingRepository = bindingRepository
        self.runtimeRepository = runtimeRepository
        self.threadAuthorityCoordinator = threadAuthorityCoordinator
        self.workspaceRoot = workspaceRoot
    }

    public init(workspaceRoot: URL) {
        self.init(
            workspaceRoot: workspaceRoot,
            workspacePersistence: InMemoryWorkspacePersistence()
        )
    }

    /// Creates a new workspace and saves it to persistence.
    public func createWorkspace(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originID: UUID? = nil,
        rootPath: String? = nil
    ) async throws -> WorkspaceReference {
        let workspace = WorkspaceReference(
            uri: uri,
            location: location,
            originID: originID,
            rootPath: rootPath
        )
        do {
            try await persistenceService.saveWorkspace(workspace)
            return workspace
        } catch let originalError {
            // `saveWorkspace` may have written before reporting a failure. Workspace IDs are
            // allocated for this creation, so an idempotent delete safely compensates either
            // outcome while preserving the original persistence error.
            do {
                try await persistenceService.deleteWorkspace(id: workspace.id)
            } catch let cleanupError {
                logCreationCleanupFailure(
                    operation: "deleteWorkspace",
                    workspaceID: workspace.id,
                    originalError: originalError,
                    cleanupError: cleanupError
                )
            }
            throw originalError
        }
    }

    /// Creates a new agent workspace and seeds it with template files.
    public func createAgentWorkspace(
        agentID: UUID,
        template: AgentTemplate? = nil
    ) async throws -> WorkspaceReference {
        // 1. Create workspace directory
        let agentWorkspaceURL = workspaceRoot
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agentID.uuidString, isDirectory: true)
        let notesDir = agentWorkspaceURL.appendingPathComponent("Notes", isDirectory: true)
        let didCreateAgentWorkspace = !FileManager.default.fileExists(atPath: agentWorkspaceURL.path)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        do {
            // 2. Establish the Agent identity file. Existing workspaces are never overwritten;
            // approved runtime edits remain authoritative across lifecycle calls.
            let soulURL = agentWorkspaceURL.appendingPathComponent("SOUL.md")
            if !FileManager.default.fileExists(atPath: soulURL.path) {
                try Self.defaultSoulContent(template: template).write(
                    to: soulURL,
                    atomically: true,
                    encoding: .utf8
                )
            }

            // 3. Seed Notes files.
            var seededPaths = Set<String>()
            if let seed = template?.workspaceFilesSeed, !seed.isEmpty {
                for (filename, content) in seed {
                    let destination = try PathSanitizer.safelyResolve(
                        path: filename,
                        within: notesDir.path,
                        jailRoot: notesDir.path
                    )
                    // Create intermediate directories safely after validating the destination
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try content.write(
                        to: destination,
                        atomically: true,
                        encoding: .utf8
                    )
                    seededPaths.insert(filename)
                }
            }
            let defaultMemoryURL = notesDir.appendingPathComponent("MEMORY.md")
            if !seededPaths.contains("MEMORY.md"),
               !FileManager.default.fileExists(atPath: defaultMemoryURL.path)
            {
                try Self.defaultMemoryContent.write(
                    to: defaultMemoryURL,
                    atomically: true,
                    encoding: .utf8
                )
            }

            // 4. Persist and return reference
            return try await createWorkspace(
                uri: .agentWorkspace(agentID),
                location: .runtime,
                originID: nil,
                rootPath: agentWorkspaceURL.path
            )
        } catch let originalError {
            if didCreateAgentWorkspace {
                do {
                    try FileManager.default.removeItem(at: agentWorkspaceURL)
                } catch let cleanupError {
                    logCreationCleanupFailure(
                        operation: "removeDirectory",
                        workspaceID: agentID,
                        originalError: originalError,
                        cleanupError: cleanupError
                    )
                }
            }
            throw originalError
        }
    }

    private static let defaultMemoryContent = """
    # Memory

    Keep durable facts, preferences, and decisions here. Prefer short, dated entries and link to
    more specific notes when a topic grows. Read the Notes catalog first, then load this file only
    when the current task needs it.
    """

    private static func defaultSoulContent(template: AgentTemplate?) -> String {
        let identity = template?.composedInstructions ?? "You are a helpful PositronicKit Agent."
        return """
        \(identity)

        ## Memory system
        Persistent memory lives in Markdown files under `Notes/`. The runtime provides a compact
        catalog of those files; read a file with `read_file` when its contents are relevant, and
        use `write_file`, `append_file`, or `edit_file` to maintain durable state. Keep notes
        concise, factual, and scoped to information that should survive future Threads.

        ## Self-modification
        This file defines the Agent's identity and operating guidance. Changes to `SOUL.md` require
        explicit user approval and take effect on the next Turn. Do not weaken safety boundaries,
        conceal changes, or treat an unapproved edit as complete. Ordinary files in the private
        workspace may be maintained without approval.
        """
    }

    /// Fetches a workspace by its unique identifier.
    public func getWorkspace(id: UUID, includeTools: Bool) async throws -> WorkspaceReference? {
        return try await persistenceService.fetchWorkspace(id: id, includeTools: includeTools)
    }

    /// Lists all workspaces.
    public func listWorkspaces() async throws -> [WorkspaceReference] {
        return try await persistenceService.fetchAllWorkspaces()
    }

    /// Deletes a workspace.
    public func deleteWorkspace(id: UUID, deleteDirectory: Bool) async throws {
        try await withWorkspaceAuthority(id) { [self] in
            try await self.deleteWorkspaceLocked(id: id, deleteDirectory: deleteDirectory)
        }
    }

    private func deleteWorkspaceLocked(id: UUID, deleteDirectory: Bool) async throws {
        try await requireWorkspaceMutationAllowed(id: id)
        if deleteDirectory,
           let workspace = try await getWorkspace(id: id, includeTools: false)
        {
            guard workspace.location != .attached else {
                throw WorkspaceError.accessDenied
            }
            guard let rootPath = workspace.rootPath else {
                try await requireWorkspaceMutationAllowed(id: id)
                try await persistenceService.deleteWorkspace(id: id)
                return
            }
            let url = try validatedDeletionURL(for: rootPath)
            try await requireWorkspaceMutationAllowed(id: id)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try await requireWorkspaceMutationAllowed(id: id)
        try await persistenceService.deleteWorkspace(id: id)
    }

    private func validatedDeletionURL(for rootPath: String) throws -> URL {
        let canonicalWorkspaceRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalTarget = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let workspaceRootComponents = canonicalWorkspaceRoot.pathComponents
        let targetComponents = canonicalTarget.pathComponents

        guard targetComponents.count > workspaceRootComponents.count,
              zip(workspaceRootComponents, targetComponents).allSatisfy(==)
        else {
            throw WorkspaceError.accessDenied
        }

        return canonicalTarget
    }

    private func logCreationCleanupFailure(
        operation: String,
        workspaceID: UUID,
        originalError: Error,
        cleanupError: Error
    ) {
        var metadata = LoggingMetadata.makeMetadata(
            for: cleanupError,
            correlationID: workspaceID.uuidString
        )
        metadata[LogKeys.stage] = .string("workspace-catalog.create")
        metadata["operation"] = .string(operation)
        metadata["entityID"] = .string(workspaceID.uuidString)

        logger.error(
            """
            Workspace creation cleanup failed — operation: \(operation), entity: \(workspaceID.uuidString.prefix(8)), \
            original error: \(ErrorKit.userFriendlyMessage(for: originalError)), \
            cleanup error: \(ErrorKit.userFriendlyMessage(for: cleanupError))
            """,
            metadata: metadata
        )
    }

    /// Updates an existing workspace.
    public func updateWorkspace(_ workspace: WorkspaceReference) async throws {
        try await withWorkspaceAuthority(workspace.id) { [self] in
            try await self.updateWorkspaceLocked(workspace)
        }
    }

    private func updateWorkspaceLocked(_ workspace: WorkspaceReference) async throws {
        try await requireWorkspaceMutationAllowed(id: workspace.id)
        try await persistenceService.saveWorkspace(workspace)
    }

    private func withWorkspaceAuthority<T: Sendable>(
        _ workspaceID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let bindingRepository,
              let threadAuthorityCoordinator,
              let threadID = try await bindingRepository.threadID(for: workspaceID)
        else {
            return try await operation()
        }
        return try await threadAuthorityCoordinator.withThread(threadID, operation: operation)
    }

    private func requireWorkspaceMutationAllowed(id: UUID) async throws {
        guard let bindingRepository, let runtimeRepository,
              let threadID = try await bindingRepository.threadID(for: id),
              let activeTurn = try await runtimeRepository.fetchActiveTurn(for: threadID)
        else { return }
        throw ThreadRuntimeRepositoryError.threadBusy(
            threadID: threadID,
            activeTurnID: activeTurn.identity.turnID
        )
    }
}
