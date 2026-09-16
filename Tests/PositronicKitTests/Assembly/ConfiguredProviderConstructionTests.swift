import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Configured provider construction", .tags(.integration))
struct ConfiguredProviderConstructionTests {
    @Test("durable configuration accepts a configured provider without client-set assembly")
    func durableConfigurationAcceptsConfiguredProvider() async throws {
        let client = MockLLMClient()
        client.nextResponse = "provider reply"
        let provider = ConfiguredLLMProvider(
            configuration: .fixture(
                endpoint: "https://api.openai.com",
                modelName: "gpt-4o",
                apiKey: "sk-test",
                activeProvider: .openAI
            ),
            client: client
        )
        let repository = InMemoryTimelineRuntimeRepository(isDurable: true)
        let store = MockPersistenceService()
        store.mockIsDurable = true

        let configuration = PKRuntime.Configuration(
            provider: provider,
            persistence: .fullyPersistent(
                runtimeRepository: repository,
                workspacePersistence: store,
                toolPersistence: store,
                agentStore: store,
                requestOriginStore: store
            )
        )
        let kit = PKRuntime(configuration: configuration)

        // The durable repository and stores survive into the assembled graph.
        #expect(kit.runtimeRepository as AnyObject === repository as AnyObject)
        #expect(kit.workspacePersistence as AnyObject === store as AnyObject)

        // The provider overload resolves through the same `LLMService` the facade's
        // `init(provider:)` path uses, so consumers never name `LLMClientSet`.
        let service = try #require(kit.languageModel as? LLMService)
        #expect(await service.configuration == provider.configuration)

        // The provider's own client, not a rebuilt one, dispatches the Turn.
        let timeline = try await kit.timelines.create(title: "Provider path")
        let turn = try await kit.timelines.open(timeline.id).startDirectTurn(
            "hello durable provider",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await turn.events().collect()

        #expect(try await turn.outcome() == .completed)
        #expect(client.messageHistory.count == 1)
        #expect(client.messageHistory.first?.last?.content == "hello durable provider")
    }
}
