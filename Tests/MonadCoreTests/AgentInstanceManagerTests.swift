import Dependencies
import Foundation
@testable import MonadCore
import MonadShared
import MonadTestSupport
import Testing

struct AgentInstanceManagerTests {
    private let mock = MockPersistenceService()

    @Test("Validation: Name too short")
    func nameTooShort() async throws {
        let repo = AgentWorkspaceService(workspaceRoot: URL(fileURLWithPath: "/tmp/monad-test"))
        let manager = AgentInstanceManager(repository: repo)

        await #expect(throws: AgentInstanceError.self) {
            _ = try await manager.createInstance(name: "Ab", description: "Valid desc")
        }
    }

    @Test("Validation: Description empty")
    func descriptionEmpty() async throws {
        let repo = AgentWorkspaceService(workspaceRoot: URL(fileURLWithPath: "/tmp/monad-test"))
        let manager = AgentInstanceManager(repository: repo)

        await #expect(throws: AgentInstanceError.self) {
            _ = try await manager.createInstance(name: "Valid Name", description: "  ")
        }
    }

    @Test("Robustness: Cannot attach to private timeline")
    func cannotAttachToPrivate() async throws {
        let repo = AgentWorkspaceService(workspaceRoot: URL(fileURLWithPath: "/tmp/monad-test"))
        let manager = AgentInstanceManager(repository: repo)

        let agentId = UUID()
        let agent = AgentInstance(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceId: UUID(), privateTimelineId: UUID())
        let otherAgentId = UUID()
        let otherAgent = AgentInstance(id: otherAgentId, name: "Other Agent", description: "Desc", primaryWorkspaceId: UUID(), privateTimelineId: UUID())
        let privateTimeline = Timeline(id: UUID(), title: "Private", attachedAgentInstanceId: agentId, isPrivate: true)

        try await TestDependencies()
            .withMocks(persistence: mock)
            .run {
                try await mock.saveAgentInstance(agent)
                try await mock.saveAgentInstance(otherAgent)
                try await mock.saveTimeline(privateTimeline)

                // Fails: attaching different agent to private timeline
                await #expect(throws: AgentInstanceError.self) {
                    try await manager.attach(agentId: otherAgentId, to: privateTimeline.id)
                }

                // Succeeds: attaching owner (idempotent)
                try await manager.attach(agentId: agent.id, to: privateTimeline.id)
            }
    }

    @Test("Robustness: Cannot detach agent from its own private timeline")
    func cannotDetachFromOwnPrivate() async throws {
        let repo = AgentWorkspaceService(workspaceRoot: URL(fileURLWithPath: "/tmp/monad-test"))
        let manager = AgentInstanceManager(repository: repo)

        let agentId = UUID()
        let agent = AgentInstance(id: agentId, name: "Test Agent", description: "Desc", primaryWorkspaceId: UUID(), privateTimelineId: UUID())
        let privateTimeline = Timeline(id: agent.privateTimelineId, title: "Private", attachedAgentInstanceId: agentId, isPrivate: true)

        try await TestDependencies()
            .withMocks(persistence: mock)
            .run {
                try await mock.saveAgentInstance(agent)
                try await mock.saveTimeline(privateTimeline)

                await #expect(throws: AgentInstanceError.self) {
                    try await manager.detach(agentId: agentId, from: privateTimeline.id)
                }
            }
    }

    @Test("Creation: Agent is automatically attached to private timeline")
    func createInstanceAttachesAgent() async throws {
        let repo = AgentWorkspaceService(workspaceRoot: URL(fileURLWithPath: "/tmp/monad-test"))
        let manager = AgentInstanceManager(repository: repo)

        try await TestDependencies()
            .withMocks(persistence: mock)
            .run {
                let instance = try await manager.createInstance(name: "New Agent", description: "Desc")

                let timeline = try await mock.fetchTimeline(id: instance.privateTimelineId)
                #expect(timeline?.attachedAgentInstanceId == instance.id)
                #expect(timeline?.isPrivate == true)
            }
    }

    @Test("Search: Find by name or description")
    func searchInstances() async throws {
        let repo = AgentWorkspaceService(workspaceRoot: URL(fileURLWithPath: "/tmp/monad-test"))
        let manager = AgentInstanceManager(repository: repo)

        let agent1 = AgentInstance(id: UUID(), name: "Researcher", description: "Finds things", primaryWorkspaceId: UUID(), privateTimelineId: UUID())
        let agent2 = AgentInstance(id: UUID(), name: "Coder", description: "Writes Swift", primaryWorkspaceId: UUID(), privateTimelineId: UUID())

        try await TestDependencies()
            .withMocks(persistence: mock)
            .run {
                try await mock.saveAgentInstance(agent1)
                try await mock.saveAgentInstance(agent2)

                let resultsName = try await manager.searchInstances(query: "research")
                #expect(resultsName.count == 1)
                #expect(resultsName.first?.name == "Researcher")

                let resultsDesc = try await manager.searchInstances(query: "Swift")
                #expect(resultsDesc.count == 1)
                #expect(resultsDesc.first?.name == "Coder")

                let resultsEmpty = try await manager.searchInstances(query: "")
                #expect(resultsEmpty.count == 2)
            }
    }
}
