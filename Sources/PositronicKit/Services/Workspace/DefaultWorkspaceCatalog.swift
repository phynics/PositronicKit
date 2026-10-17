import ErrorKit
import Foundation
import Logging
import PKContracts
import PKUtilities

/// Manages the persistence and provisioning of agent private workspaces.
///
/// Handles workspace CRUD (delegating to `workspacePersistence`) and agent-specific
/// provisioning: creating sandboxed directories and seeding them from template files.
/// This is the default local/runtime provisioning service shipped with PKRuntime, not a
/// universal workspace model that hosts are required to adopt.
actor DefaultWorkspaceCatalog: WorkspaceCatalog {
    private let persistenceService: any WorkspaceStore
    private let bindingRepository: any WorkspaceBindingRepository?
    private let runtimeRepository: any TimelineRuntimeRepository?
    private let timelineAuthorityCoordinator: TimelineAuthorityCoordinator?
    private let workspaceRoot: URL
    private let agentWorkspaceSeed: AgentWorkspaceSeed
    private let logger = Logger.module(named: "workspace-catalog")

    public init(
        workspaceRoot: URL,
        workspacePersistence: any WorkspaceStore,
        bindingRepository: any WorkspaceBindingRepository? = nil,
        runtimeRepository: any TimelineRuntimeRepository? = nil,
        timelineAuthorityCoordinator: TimelineAuthorityCoordinator? = nil,
        agentWorkspaceSeed: AgentWorkspaceSeed = .none
    ) {
        persistenceService = workspacePersistence
        // The binding repository is resolved exactly once, by `PersistenceConfiguration`
        // (ADR 0004: binding authority is repository-only). This seam receives it rather than
        // inferring it from an `as?` downcast of `workspacePersistence` (C-02) — a caller that
        // wants binding-aware behavior (ownership checks before workspace deletion) must pass
        // one explicitly.
        self.bindingRepository = bindingRepository
        self.runtimeRepository = runtimeRepository
        self.timelineAuthorityCoordinator = timelineAuthorityCoordinator
        self.workspaceRoot = workspaceRoot
        self.agentWorkspaceSeed = agentWorkspaceSeed
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
        try await createWorkspace(
            uri: uri,
            location: location,
            originID: originID,
            rootPath: rootPath,
            metadata: nil
        )
    }

    /// Creates a new workspace and saves it to persistence with host-owned metadata.
    public func createWorkspace(
        uri: WorkspaceURI,
        location: WorkspaceReference.WorkspaceLocation,
        originID: UUID? = nil,
        rootPath: String? = nil,
        metadata: [String: AnyCodable]?
    ) async throws -> WorkspaceReference {
        let workspace = WorkspaceReference(
            uri: uri,
            location: location,
            originID: originID,
            rootPath: rootPath,
            metadata: metadata
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
            // 2. Establish the Agent identity file when the configured seed provides one.
            // Existing workspaces are never overwritten; approved runtime edits remain
            // authoritative across lifecycle calls.
            if let identityFilename = agentWorkspaceSeed.identityFilename {
                let identityURL = agentWorkspaceURL.appendingPathComponent(identityFilename)
                let identityContent = agentWorkspaceSeed.identityContent(template)
                if !identityContent.isEmpty, !FileManager.default.fileExists(atPath: identityURL.path) {
                    try identityContent.write(
                        to: identityURL,
                        atomically: true,
                        encoding: .utf8
                    )
                }
            }

            // 3. Seed Notes files from the template, then from the configured Agent seed.
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
            for (filename, content) in agentWorkspaceSeed.notes
                where !seededPaths.contains(filename)
            {
                let destination = try PathSanitizer.safelyResolve(
                    path: filename,
                    within: notesDir.path,
                    jailRoot: notesDir.path
                )
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
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

    /// Fetches a workspace by its unique identifier.
    public func fetchWorkspace(id: UUID, includeTools: Bool) async throws -> WorkspaceReference? {
        return try await persistenceService.fetchWorkspace(id: id, includeTools: includeTools)
    }

    /// Lists all workspaces.
    public func listWorkspaces() async throws -> [WorkspaceReference] {
        return try await persistenceService.fetchAllWorkspaces()
    }

    /// Deletes a workspace.
    public func deleteWorkspace(id: UUID, includingDirectory: Bool) async throws {
        try await withWorkspaceAuthority(id) { [self] in
            try await self.deleteWorkspaceLocked(id: id, includingDirectory: includingDirectory)
        }
    }

    private func deleteWorkspaceLocked(id: UUID, includingDirectory: Bool) async throws {
        try await requireWorkspaceMutationAllowed(id: id)
        if includingDirectory,
           let workspace = try await fetchWorkspace(id: id, includeTools: false)
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
              let timelineAuthorityCoordinator,
              let timelineID = try await bindingRepository.timelineID(for: workspaceID)
        else {
            return try await operation()
        }
        return try await timelineAuthorityCoordinator.withTimeline(timelineID, operation: operation)
    }

    private func requireWorkspaceMutationAllowed(id: UUID) async throws {
        guard let bindingRepository, let runtimeRepository,
              let timelineID = try await bindingRepository.timelineID(for: id),
              let activeTurn = try await runtimeRepository.fetchActiveTurn(for: timelineID)
        else { return }
        throw TimelineRuntimeRepositoryError.timelineBusy(
            timelineID: timelineID,
            activeTurnID: activeTurn.identity.turnID
        )
    }
}
