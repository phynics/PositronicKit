import ErrorKit
import Foundation
import Logging
import PKShared
import PKUtilities

/// Manages the persistence and provisioning of agent private workspaces.
///
/// Handles workspace CRUD (delegating to `workspacePersistence`) and agent-specific
/// provisioning: creating sandboxed directories and seeding them from template files.
/// This is the default local/runtime provisioning service shipped with PositronicKit, not a
/// universal workspace model that hosts are required to adopt.
public actor DefaultWorkspaceCatalog: WorkspaceCatalog {
    private let persistenceService: any WorkspaceStore
    private let workspaceRoot: URL
    private let logger = Logger.module(named: "workspace-catalog")

    public init(
        workspaceRoot: URL,
        workspacePersistence: any WorkspaceStore
    ) {
        persistenceService = workspacePersistence
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
        instanceID: UUID,
        template: AgentTemplate? = nil
    ) async throws -> WorkspaceReference {
        // 1. Create workspace directory
        let agentWorkspaceURL = workspaceRoot
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(instanceID.uuidString, isDirectory: true)
        let notesDir = agentWorkspaceURL.appendingPathComponent("Notes", isDirectory: true)
        let didCreateAgentWorkspace = !FileManager.default.fileExists(atPath: agentWorkspaceURL.path)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        do {
            // 2. Seed workspace files
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
                }
            } else if let template = template {
                // Default: write composed instructions as system.md
                try template.composedInstructions.write(
                    to: notesDir.appendingPathComponent("system.md"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            // 3. Persist and return reference
            return try await createWorkspace(
                uri: .agentWorkspace(instanceID),
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
                        workspaceID: instanceID,
                        originalError: originalError,
                        cleanupError: cleanupError
                    )
                }
            }
            throw originalError
        }
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
        if deleteDirectory,
           let workspace = try await getWorkspace(id: id, includeTools: false)
        {
            guard workspace.location != .attached else {
                throw WorkspaceError.accessDenied
            }
            guard let rootPath = workspace.rootPath else {
                try await persistenceService.deleteWorkspace(id: id)
                return
            }
            let url = try validatedDeletionURL(for: rootPath)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
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
        try await persistenceService.saveWorkspace(workspace)
    }
}
