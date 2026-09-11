import Foundation
import PKContracts
import PositronicKit
internal import Testing

/// Runs the documented behavioral checks for a ``ToolPersistenceProtocol`` implementation.
public enum ToolPersistenceConformanceSuite {
    /// Runs the tool-persistence checks against an isolated store seeded with the supplied
    /// workspaces for each scenario.
    public static func run(
        makeStore: ([WorkspaceReference]) async throws -> any ToolPersistenceProtocol
    ) async throws {
        try await runScenario("tool.add.fetch") {
            try await addsAndFetchesTools(makeStore: makeStore)
        }
        try await runScenario("tool.missing-workspace") {
            try await rejectsMissingWorkspace(makeStore: makeStore)
        }
        try await runScenario("tool.sync") {
            try await synchronizesTools(makeStore: makeStore)
        }
        try await runScenario("tool.origin.filter") {
            try await filtersByOrigin(makeStore: makeStore)
        }
        try await runScenario("tool.owner.scope") {
            try await findsOwnersWithinScope(makeStore: makeStore)
        }
        try await runScenario("tool.source") {
            try await resolvesToolSource(makeStore: makeStore)
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

    private static func addsAndFetchesTools(
        makeStore: ([WorkspaceReference]) async throws -> any ToolPersistenceProtocol
    ) async throws {
        let workspaceID = UUID()
        let workspace = makeWorkspace(id: workspaceID, tools: [.known("existing")])
        let store = try await makeStore([workspace])
        try await store.addToolToWorkspace(workspaceId: workspaceID, tool: .known("added"))

        let tools = try await store.fetchTools(forWorkspaces: [workspaceID])
        try #require(
            tools.count == 2 && Set(tools.map(\.toolID)) == Set(["existing", "added"]),
            "tool.add.fetch"
        )
        try #require(try await store.fetchTools(forWorkspaces: [UUID()]).isEmpty, "tool.add.scope")
    }

    private static func rejectsMissingWorkspace(
        makeStore: ([WorkspaceReference]) async throws -> any ToolPersistenceProtocol
    ) async throws {
        let store = try await makeStore([])
        do {
            try await store.addToolToWorkspace(workspaceId: UUID(), tool: .known("missing"))
            Issue.record("tool.missing-workspace.must-fail")
            return
        } catch {
            // The protocol requires failure, but does not require one concrete error type.
        }

        do {
            try await store.syncTools(workspaceId: UUID(), tools: [.known("missing")])
            Issue.record("tool.missing-workspace.sync-must-fail")
            return
        } catch {
            // The protocol requires failure, but does not require one concrete error type.
        }
    }

    private static func synchronizesTools(
        makeStore: ([WorkspaceReference]) async throws -> any ToolPersistenceProtocol
    ) async throws {
        let workspaceID = UUID()
        let store = try await makeStore([
            makeWorkspace(id: workspaceID, tools: [.known("old"), .known("removed")])
        ])
        try await store.syncTools(workspaceId: workspaceID, tools: [.known("new")])

        let tools = try await store.fetchTools(forWorkspaces: [workspaceID])
        try #require(tools.map(\.toolID) == ["new"], "tool.sync.replaces-all")
    }

    private static func filtersByOrigin(
        makeStore: ([WorkspaceReference]) async throws -> any ToolPersistenceProtocol
    ) async throws {
        let originID = UUID()
        let store = try await makeStore([
            makeWorkspace(id: UUID(), originID: originID, tools: [.known("origin-tool")]),
            makeWorkspace(id: UUID(), originID: UUID(), tools: [.known("other-tool")])
        ])

        let tools = try await store.fetchOriginTools(originId: originID)
        try #require(tools.map(\.toolID) == ["origin-tool"], "tool.origin.filter")
    }

    private static func findsOwnersWithinScope(
        makeStore: ([WorkspaceReference]) async throws -> any ToolPersistenceProtocol
    ) async throws {
        let ownerID = UUID()
        let outsideID = UUID()
        let store = try await makeStore([
            makeWorkspace(id: ownerID, tools: [.known("echo")]),
            makeWorkspace(id: outsideID, tools: [.known("outside")])
        ])

        try #require(
            try await store.findWorkspaceId(forToolId: "echo", in: [ownerID]) == ownerID,
            "tool.owner.found"
        )
        try #require(
            try await store.findWorkspaceId(forToolId: "outside", in: [ownerID]) == nil,
            "tool.owner.scope"
        )
        try #require(
            try await store.findWorkspaceId(forToolId: "missing", in: [ownerID, outsideID]) == nil,
            "tool.owner.unknown"
        )
    }

    private static func resolvesToolSource(
        makeStore: ([WorkspaceReference]) async throws -> any ToolPersistenceProtocol
    ) async throws {
        let workspaceID = UUID()
        let store = try await makeStore([
            makeWorkspace(id: workspaceID, tools: [.known("echo")])
        ])

        try #require(
            try await store.fetchToolSource(
                toolId: "echo",
                workspaceIds: [workspaceID],
                primaryWorkspaceId: nil
            ) != nil,
            "tool.source.known"
        )
        try #require(
            try await store.fetchToolSource(
                toolId: "missing",
                workspaceIds: [workspaceID],
                primaryWorkspaceId: nil
            ) == nil,
            "tool.source.unknown"
        )

        let outsideID = UUID()
        let scopedStore = try await makeStore([
            makeWorkspace(id: workspaceID, tools: [.known("echo")]),
            makeWorkspace(id: outsideID, tools: [.known("outside")])
        ])
        try #require(
            try await scopedStore.fetchToolSource(
                toolId: "outside",
                workspaceIds: [workspaceID],
                primaryWorkspaceId: nil
            ) == nil,
            "tool.source.out-of-scope"
        )
    }

    private static func makeWorkspace(
        id: UUID = UUID(),
        originID: UUID? = nil,
        tools: [ToolReference] = []
    ) -> WorkspaceReference {
        WorkspaceReference(
            id: id,
            uri: WorkspaceURI(host: "pk-conformance", path: "/(id.uuidString)"),
            location: .runtime,
            originID: originID,
            tools: tools,
            rootPath: "/tmp/pk-conformance"
        )
    }
}
