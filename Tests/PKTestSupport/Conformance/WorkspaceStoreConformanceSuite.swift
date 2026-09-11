import Foundation
import PKContracts
import PositronicKit
internal import Testing

/// Runs the documented behavioral checks for a ``WorkspaceStore`` implementation.
public enum WorkspaceStoreConformanceSuite {
    /// Runs the workspace-store checks against an isolated store for every scenario.
    public static func run(
        makeStore: () async throws -> any WorkspaceStore
    ) async throws {
        try await runScenario("workspace.empty") {
            try await emptyStoreReads(makeStore: makeStore)
        }
        try await runScenario("workspace.save.fetch") {
            try await savesAndFetches(makeStore: makeStore)
        }
        try await runScenario("workspace.replace") {
            try await replacesByID(makeStore: makeStore)
        }
        try await runScenario("workspace.fetch-all") {
            try await fetchesAllWorkspaces(makeStore: makeStore)
        }
        try await runScenario("workspace.delete") {
            try await deletesOneWorkspace(makeStore: makeStore)
        }
    }

    private struct ScenarioError: Error, CustomStringConvertible {
        let id: String
        let underlying: Error

        var description: String { "\(id): \(String(describing: underlying))" }
    }

    private static func runScenario(
        _ id: String,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            if error is Testing.ExpectationFailedError {
                throw error
            }
            throw ScenarioError(id: id, underlying: error)
        }
    }

    private static func emptyStoreReads(
        makeStore: () async throws -> any WorkspaceStore
    ) async throws {
        let store = try await makeStore()
        try #require(try await store.fetchWorkspace(id: UUID(), includeTools: false) == nil, "workspace.empty.fetch")
        try #require(try await store.fetchAllWorkspaces().isEmpty, "workspace.empty.all")
    }

    private static func savesAndFetches(
        makeStore: () async throws -> any WorkspaceStore
    ) async throws {
        let store = try await makeStore()
        let workspace = makeWorkspace()
        try await store.saveWorkspace(workspace)
        let fetched = try #require(
            try await store.fetchWorkspace(id: workspace.id, includeTools: true),
            "workspace.save.fetch"
        )
        try expectEquivalent(fetched, workspace, scenario: "workspace.save.fetch")
    }

    private static func replacesByID(
        makeStore: () async throws -> any WorkspaceStore
    ) async throws {
        let store = try await makeStore()
        let id = UUID()
        let original = makeWorkspace(id: id, location: .runtime)
        let updated = makeWorkspace(id: id, location: .attached, rootPath: "/projects/updated")
        try await store.saveWorkspace(original)
        try await store.saveWorkspace(updated)

        let fetched = try #require(
            try await store.fetchWorkspace(id: id, includeTools: false),
            "workspace.replace.fetch"
        )
        try expectEquivalent(fetched, updated, scenario: "workspace.replace.fetch")
        try #require(try await store.fetchAllWorkspaces().count == 1, "workspace.replace.unique-id")
    }

    private static func fetchesAllWorkspaces(
        makeStore: () async throws -> any WorkspaceStore
    ) async throws {
        let store = try await makeStore()
        let workspaces = [makeWorkspace(), makeWorkspace(), makeWorkspace()]
        for workspace in workspaces {
            try await store.saveWorkspace(workspace)
        }

        let fetched = try await store.fetchAllWorkspaces()
        try #require(
            fetched.count == workspaces.count && Set(fetched.map(\.id)) == Set(workspaces.map(\.id)),
            "workspace.fetch-all.membership"
        )
    }

    private static func deletesOneWorkspace(
        makeStore: () async throws -> any WorkspaceStore
    ) async throws {
        let store = try await makeStore()
        let keep = makeWorkspace()
        let remove = makeWorkspace()
        try await store.saveWorkspace(keep)
        try await store.saveWorkspace(remove)

        try await store.deleteWorkspace(id: remove.id)
        try #require(try await store.fetchWorkspace(id: remove.id, includeTools: false) == nil, "workspace.delete.removes-target")
        try #require(try await store.fetchWorkspace(id: keep.id, includeTools: false) != nil, "workspace.delete.preserves-other")

        try await store.deleteWorkspace(id: UUID())
        try #require(try await store.fetchWorkspace(id: keep.id, includeTools: false) != nil, "workspace.delete.unknown-idempotent")
    }

    private static func makeWorkspace(
        id: UUID = UUID(),
        location: WorkspaceReference.WorkspaceLocation = .runtime,
        rootPath: String? = "/tmp/pk-conformance"
    ) -> WorkspaceReference {
        WorkspaceReference(
            id: id,
            uri: WorkspaceURI(host: "pk-conformance", path: "/(id.uuidString)"),
            location: location,
            rootPath: rootPath
        )
    }

    private static func expectEquivalent(
        _ actual: WorkspaceReference,
        _ expected: WorkspaceReference,
        scenario: String
    ) throws {
        try #require(actual.id == expected.id, "\(scenario).id")
        try #require(actual.uri == expected.uri, "\(scenario).uri")
        try #require(actual.location == expected.location, "\(scenario).location")
        try #require(actual.originID == expected.originID, "\(scenario).origin")
        try #require(actual.tools == expected.tools, "\(scenario).tools")
        try #require(actual.rootPath == expected.rootPath, "\(scenario).root-path")
        try #require(actual.trustLevel == expected.trustLevel, "\(scenario).trust")
        try #require(actual.lastModifiedBy == expected.lastModifiedBy, "\(scenario).last-modified-by")
        try #require(actual.status == expected.status, "\(scenario).status")
        try #require(actual.contextInjection == expected.contextInjection, "\(scenario).context")
        try #require(actual.createdAt == expected.createdAt, "\(scenario).created-at")
    }
}
