import Foundation
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Direct Turn context")
struct DirectTurnContextTests {
    @Test("omitted contributors use the conventional host contributor")
    func defaultsToHostContributor() {
        let context = DirectTurnContext(systemInstructions: "Be concise.")

        #expect(context.contributors == [.host])
    }

    @Test("omitted and explicit host contexts are equal")
    func omittedAndExplicitHostContextsAreEqual() {
        let omitted = DirectTurnContext(systemInstructions: "Be concise.")
        let explicit = DirectTurnContext(systemInstructions: "Be concise.", contributors: [.host])

        #expect(omitted == explicit)
    }

    @Test("custom contributor arrays remain unchanged")
    func customContributorsRemainUnchanged() {
        let contributors: [TurnContributor] = ["tenant", "workspace"]

        let context = DirectTurnContext(
            systemInstructions: "Be concise.",
            contributors: contributors
        )

        #expect(context.contributors == contributors)

        let empty = DirectTurnContext(systemInstructions: "", contributors: [])
        #expect(empty.contributors.isEmpty)
    }

    @Test("a direct Turn completes with the default contributor")
    func directTurnUsesDefaultContributor() async throws {
        let model = MockLLMService()
        model.mockClient.nextResponse = "direct reply"
        let kit = PositronicKit(languageModel: model)
        let thread = try await kit.threads.create(title: "Direct")

        let turn = try await thread.startDirectTurn(
            "hello",
            context: DirectTurnContext(systemInstructions: "")
        )
        _ = await turn.events().collect()

        #expect(try await turn.outcome() == .completed)
    }

    @Test("the default contributor preserves the request fingerprint")
    func defaultContributorPreservesFingerprint() async throws {
        let model = MockLLMService()
        model.mockClient.nextResponse = "replayed reply"
        let kit = PositronicKit(languageModel: model)
        let thread = try await kit.threads.create(title: "Replay")
        let options = TurnOptions(requestID: UUID())

        let explicit = try await thread.startDirectTurn(
            "same request",
            context: DirectTurnContext(systemInstructions: "", contributor: .host),
            options: options
        )
        _ = await explicit.events().collect()

        let omitted = try await thread.startDirectTurn(
            "same request",
            context: DirectTurnContext(systemInstructions: ""),
            options: options
        )
        _ = await omitted.events().collect()

        #expect(omitted.id == explicit.id)
        #expect(model.mockClient.streamCallCount == 1)
    }

    @Test("the default contributor reaches a custom context source")
    func defaultContributorReachesContextSource() async throws {
        let model = MockLLMService()
        model.mockClient.nextResponse = "context-aware reply"
        let source = RecordingTurnContextSource()
        let repository = InMemoryThreadRuntimeRepository()
        let kit = PositronicKit(configuration: .init(
            provider: .init(languageModel: model),
            persistence: .init(runtimeRepository: repository),
            runtime: .init(customization: RuntimeCustomization(turnContextSource: source))
        ))
        let thread = try await kit.threads.create(title: "Context source")

        let turn = try await thread.startDirectTurn(
            "hello",
            context: DirectTurnContext(systemInstructions: "")
        )
        _ = await turn.events().collect()

        let requests = await source.requests()
        #expect(requests.count == 1)
        #expect(requests.first?.contributors == [.host])
    }
}

private actor RecordingTurnContextSource: TurnContextSource {
    private var recordedRequests: [TurnContextRequest] = []

    func contributions(for request: TurnContextRequest) async throws -> [TurnContextContribution] {
        recordedRequests.append(request)
        return []
    }

    func requests() -> [TurnContextRequest] {
        recordedRequests
    }
}
