import Foundation
import PKContracts
import PKTestSupport
import PositronicKit
import struct PositronicKit.Thread
import Testing

@Suite("PKTestSupport conformance suites", .serialized)
struct ConformanceSuiteTests {
    @Test("WorkspaceStore runs against in-tree conformers")
    func workspaceStoreConformers() async throws {
        try await WorkspaceStoreConformanceSuite.run {
            InMemoryWorkspacePersistence()
        }
        try await WorkspaceStoreConformanceSuite.run {
            MockWorkspacePersistence()
        }
        try await WorkspaceStoreConformanceSuite.run {
            MockPersistenceService()
        }
    }

    @Test("ToolPersistenceProtocol runs against in-tree conformers")
    func toolPersistenceConformers() async throws {
        try await ToolPersistenceConformanceSuite.run { workspaces in
            let store = InMemoryToolPersistence()
            await store.replaceWorkspaces(workspaces)
            return store
        }
        try await ToolPersistenceConformanceSuite.run { workspaces in
            let store = MockToolPersistence()
            store.workspaces = workspaces
            return store
        }
        try await ToolPersistenceConformanceSuite.run { workspaces in
            let store = MockPersistenceService()
            store.workspaces = workspaces
            return store
        }
    }

    @Test("AgentStoreProtocol runs against seeded in-tree conformers")
    func agentStoreConformers() async throws {
        try await AgentStoreConformanceSuite.run { threads in
            InMemoryAgentStore(threads: threads)
        }
        try await AgentStoreConformanceSuite.run { threads in
            let store = MockPersistenceService()
            store.threads = threads
            return store
        }
    }

    @Test("RequestOriginStoreProtocol runs against in-tree conformers")
    func requestOriginStoreConformers() async throws {
        try await RequestOriginStoreConformanceSuite.run {
            InMemoryRequestOriginStore()
        }
        try await RequestOriginStoreConformanceSuite.run {
            DictionaryRequestOriginStore()
        }
    }

    @Test("WorkspaceFactory runs against the in-tree factory")
    func workspaceFactoryConformer() throws {
        try WorkspaceFactoryConformanceSuite.run(
            factory: MockWorkspaceCreator(),
            supportedReference: Self.makeWorkspace()
        )
    }

    @Test("broken ThreadRuntimeRepository is reported at terminal completion")
    func brokenThreadRuntimeRepository() async throws {
        await withKnownIssue("thread.completion.outcome: broken fixture must be observed") {
            try await ThreadRuntimeRepositoryConformanceSuite.run(staleAfter: 300) {
                let store = MockPersistenceService()
                store.completeTurnFails = true
                return store
            }
        }
    }

    @Test("broken WorkspaceStore is reported at save/fetch")
    func brokenWorkspaceStore() async throws {
        await withKnownIssue("workspace.save.fetch: broken fixture must be observed") {
            try await WorkspaceStoreConformanceSuite.run {
                BrokenWorkspaceStore()
            }
        }
    }

    @Test("broken ToolPersistenceProtocol is reported at add/fetch")
    func brokenToolPersistence() async throws {
        await withKnownIssue("tool.add.fetch: broken fixture must be observed") {
            try await ToolPersistenceConformanceSuite.run { workspaces in
                BrokenToolPersistence(workspaces: workspaces)
            }
        }
    }

    @Test("broken AgentStoreProtocol is reported at save/fetch")
    func brokenAgentStore() async throws {
        await withKnownIssue("agent.save.fetch: broken fixture must be observed") {
            try await AgentStoreConformanceSuite.run { threads in
                BrokenAgentStore(threads: threads)
            }
        }
    }

    @Test("broken RequestOriginStoreProtocol is reported at save/fetch")
    func brokenRequestOriginStore() async throws {
        await withKnownIssue("origin.save.fetch: broken fixture must be observed") {
            try await RequestOriginStoreConformanceSuite.run {
                BrokenRequestOriginStore()
            }
        }
    }

    @Test("broken WorkspaceFactory is reported at reference preservation")
    func brokenWorkspaceFactory() throws {
        withKnownIssue("workspace-factory.reference.id: broken fixture must be observed") {
            try WorkspaceFactoryConformanceSuite.run(
                factory: BrokenWorkspaceFactory(),
                supportedReference: Self.makeWorkspace()
            )
        }
    }

    private static func makeWorkspace() -> WorkspaceReference {
        WorkspaceReference(
            uri: WorkspaceURI(host: "conformance", path: "/workspace"),
            location: .attached,
            originID: UUID(),
            tools: [.known("echo")],
            rootPath: "/tmp/conformance",
            trustLevel: .restricted,
            lastModifiedBy: UUID(),
            status: .active,
            contextInjection: "context",
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }
}

private actor DictionaryRequestOriginStore: RequestOriginStoreProtocol {
    private var origins: [UUID: RequestOriginIdentity] = [:]

    func saveOrigin(_ origin: RequestOriginIdentity) async throws {
        origins[origin.id] = origin
    }

    func fetchOrigin(id: UUID) async throws -> RequestOriginIdentity? {
        origins[id]
    }

    func fetchAllOrigins() async throws -> [RequestOriginIdentity] {
        Array(origins.values)
    }

    func deleteOrigin(id: UUID) async throws -> Bool {
        origins.removeValue(forKey: id) != nil
    }
}

private actor BrokenWorkspaceStore: WorkspaceStore {
    func saveWorkspace(_: WorkspaceReference) async throws {}
    func fetchWorkspace(id _: UUID, includeTools _: Bool) async throws -> WorkspaceReference? { nil }
    func fetchAllWorkspaces() async throws -> [WorkspaceReference] { [] }
    func deleteWorkspace(id _: UUID) async throws {}
}

private actor BrokenToolPersistence: ToolPersistenceProtocol {
    init(workspaces _: [WorkspaceReference]) {}
    func addToolToWorkspace(workspaceId _: UUID, tool _: ToolReference) async throws {}
    func syncTools(workspaceId _: UUID, tools _: [ToolReference]) async throws {}
    func fetchTools(forWorkspaces _: [UUID]) async throws -> [ToolReference] { [] }
    func fetchOriginTools(originId _: UUID) async throws -> [ToolReference] { [] }
    func findWorkspaceId(forToolId _: String, in _: [UUID]) async throws -> UUID? { nil }
    func fetchToolSource(toolId _: String, workspaceIds _: [UUID], primaryWorkspaceId _: UUID?) async throws -> String? { nil }
}

private actor BrokenAgentStore: AgentStoreProtocol {
    init(threads _: [Thread]) {}
    func saveAgent(_: Agent) async throws {}
    func fetchAgent(id _: UUID) async throws -> Agent? { nil }
    func fetchAllAgents() async throws -> [Agent] { [] }
    func deleteAgent(id _: UUID) async throws {}
    func fetchThreads(attachedToAgent _: UUID) async throws -> [Thread] { [] }
}

private actor BrokenRequestOriginStore: RequestOriginStoreProtocol {
    func saveOrigin(_: RequestOriginIdentity) async throws {}
    func fetchOrigin(id _: UUID) async throws -> RequestOriginIdentity? { nil }
    func fetchAllOrigins() async throws -> [RequestOriginIdentity] { [] }
    func deleteOrigin(id _: UUID) async throws -> Bool { false }
}

private struct BrokenWorkspaceFactory: WorkspaceFactory {
    func create(from reference: WorkspaceReference) throws -> any WorkspaceProvider {
        BrokenWorkspaceProvider(
            reference: WorkspaceReference(
                uri: reference.uri,
                location: reference.location
            )
        )
    }
}

private struct BrokenWorkspaceProvider: WorkspaceProvider {
    let reference: WorkspaceReference

    func healthCheck() async -> Bool { true }
}
