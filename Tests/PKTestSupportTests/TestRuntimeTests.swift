import Foundation
import PKTestSupport
import PositronicKit
import Testing

@Suite("TestRuntime")
struct TestRuntimeTests {
    @Test("Agent capability shares facade state")
    func agentCapabilitySharesFacadeState() async throws {
        let runtime = TestRuntime(
            workspaceRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-runtime-\(UUID().uuidString)")
        )

        let agent = try await runtime.agents.create(name: "Shared Agent", description: "fixture")
        #expect(try await runtime.runtime.agents.get(agent.id)?.id == agent.id)
    }

    @Test("uniqueWorkspaceRoot returns a distinct path per call")
    func uniqueWorkspaceRootReturnsDistinctPaths() {
        #expect(TestRuntime.uniqueWorkspaceRoot() != TestRuntime.uniqueWorkspaceRoot())
    }

    @Test("default repository is backed by the exposed persistence double")
    func defaultRepositoryIsBackedByPersistence() async throws {
        let persistence = MockPersistenceService()
        let runtime = TestRuntime(
            workspaceRoot: TestRuntime.uniqueWorkspaceRoot(),
            persistence: persistence
        )

        let timeline = try await runtime.timelines.create(title: "Shared Store")
        #expect(try await persistence.fetchTimeline(id: timeline.id) != nil)
        #expect(try await runtime.repository.fetchTimeline(id: timeline.id) != nil)
    }

    @Test("persistenceConfiguration overrides the default repository wiring")
    func persistenceConfigurationOverridesWiring() async throws {
        let repository = InMemoryTimelineRuntimeRepository()
        let runtime = TestRuntime(
            workspaceRoot: TestRuntime.uniqueWorkspaceRoot(),
            persistenceConfiguration: .init(runtimeRepository: repository)
        )

        let timeline = try await runtime.timelines.create(title: "Custom Store")
        #expect(try await repository.fetchTimeline(id: timeline.id) != nil)
    }

    @Test("a managed Turn is durable through the repository and TurnHandle")
    func managedTurnIsDurableThroughRepository() async throws {
        let llm = MockLLMService()
        llm.mockClient.nextChunks = [["durable"]]
        let runtime = TestRuntime(workspaceRoot: TestRuntime.uniqueWorkspaceRoot(), llm: llm)

        let timeline = try await runtime.timelines.create(title: "Durable")
        let agent = try await runtime.agents.create(name: "Durable Agent", description: "fixture")
        try await runtime.agents.attach(agent.id, to: timeline.id)
        let turn = try await runtime.timelines.open(timeline.id).startTurn("hello")

        var streamed = ""
        for await text in turn.generatedText() { streamed += text }
        #expect(streamed == "durable")

        let result = try await turn.result()
        #expect(result.outcome == .completed)

        let record = try #require(try await runtime.repository.fetchTurn(id: turn.id))
        #expect(record.outcome == .completed)
    }

    @Test("runtimeBuilder builds the facade from the assembled configuration")
    func runtimeBuilderBuildsFacade() async throws {
        let override = MockLLMService()
        override.mockClient.nextChunks = [["override"]]
        let fixture = MockLLMService()
        fixture.mockClient.nextChunks = [["fixture"]]
        let runtime = TestRuntime(
            workspaceRoot: TestRuntime.uniqueWorkspaceRoot(),
            llm: fixture,
            runtimeBuilder: { configuration in
                PKRuntime(configuration: .init(
                    languageModel: override,
                    persistence: configuration.persistence,
                    runtime: configuration.runtime,
                    generationParameters: configuration.generationParameters,
                    logging: configuration.logging
                ))
            }
        )

        let timeline = try await runtime.timelines.create(title: "Builder")
        let agent = try await runtime.agents.create(name: "Builder Agent", description: "fixture")
        try await runtime.agents.attach(agent.id, to: timeline.id)
        let turn = try await runtime.timelines.open(timeline.id).startTurn("hi")

        var streamed = ""
        for await text in turn.generatedText() { streamed += text }
        #expect(streamed == "override")
    }
}
