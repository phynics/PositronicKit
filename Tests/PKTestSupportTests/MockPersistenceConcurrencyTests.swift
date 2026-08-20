import Foundation
import PKContracts
import PKTestSupport
import Testing

@Suite("MockPersistenceService concurrency")
struct MockPersistenceConcurrencyTests {
    @Test("concurrent agent saves preserve the exact set")
    func concurrentAgentSavesPreserveExactSet() async throws {
        let persistence = MockPersistenceService()
        let agents = (0 ..< 100).map { index in
            AgentInstance(
                id: fixedUUID(index + 1),
                name: "agent-\(index)",
                description: "concurrency fixture",
                privateThreadID: fixedUUID(index + 1_001)
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for agent in agents {
                group.addTask {
                    try await persistence.saveAgentInstance(agent)
                }
            }
            try await group.waitForAll()
        }

        let saved = try await persistence.fetchAllAgentInstances()
        #expect(saved.count == agents.count)
        #expect(Set(saved.map(\.id)) == Set(agents.map(\.id)))
    }

    @Test("concurrent workspace saves preserve the exact workspace and tool sets")
    func concurrentWorkspaceSavesPreserveExactSets() async throws {
        let persistence = MockPersistenceService()
        let workspaces = (0 ..< 100).map { index in
            WorkspaceReference.fixture(
                id: fixedUUID(index + 2_001),
                uri: .threadWorkspace(fixedUUID(index + 3_001)),
                tools: [.known("tool-\(index)")]
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for workspace in workspaces {
                group.addTask {
                    try await persistence.saveWorkspace(workspace)
                }
            }
            try await group.waitForAll()
        }

        let saved = try await persistence.fetchAllWorkspaces()
        #expect(saved.count == workspaces.count)
        #expect(Set(saved.map(\.id)) == Set(workspaces.map(\.id)))

        let mirroredTools = try await persistence.fetchTools(forWorkspaces: workspaces.map(\.id))
        #expect(Set(mirroredTools.map(\.toolID)) == Set((0 ..< 100).map { "tool-\($0)" }))
    }

    private func fixedUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
