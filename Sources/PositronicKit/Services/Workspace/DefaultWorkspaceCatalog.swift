import Foundation
import PKShared

/// Manages the persistence and provisioning of agent private workspaces.
///
/// Handles workspace CRUD (delegating to `workspacePersistence`) and agent-specific
/// provisioning: creating sandboxed directories and seeding them from template files.
/// This is the default local/runtime provisioning service shipped with PositronicKit, not a
/// universal workspace model that hosts are required to adopt.
public actor DefaultWorkspaceCatalog: WorkspaceCatalog {
    private let persistenceService: any WorkspaceStore
    private let workspaceRoot: URL

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
        originId: UUID?,
        rootPath: String?
    ) async throws -> WorkspaceReference {
        let workspace = WorkspaceReference(
            uri: uri,
            location: location,
            originId: originId,
            rootPath: rootPath
        )
        try await persistenceService.saveWorkspace(workspace)
        return workspace
    }

    /// Creates a new agent workspace and seeds it with template files.
    public func createAgentWorkspace(
        instanceId: UUID,
        template: AgentTemplate?
    ) async throws -> WorkspaceReference {
        // 1. Create workspace directory
        let agentWorkspaceURL = workspaceRoot
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(instanceId.uuidString, isDirectory: true)
        let notesDir = agentWorkspaceURL.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

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
            uri: .agentWorkspace(instanceId),
            location: .runtime,
            originId: nil,
            rootPath: agentWorkspaceURL.path
        )
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
           let workspace = try await getWorkspace(id: id, includeTools: false),
           let rootPath = workspace.rootPath
        {
            let url = URL(fileURLWithPath: rootPath)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try await persistenceService.deleteWorkspace(id: id)
    }

    /// Updates an existing workspace.
    public func updateWorkspace(_ workspace: WorkspaceReference) async throws {
        try await persistenceService.saveWorkspace(workspace)
    }
}
