import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

/// Over-budget Turn behavior: projection first, then stepwise history trimming, then a
/// structured preparation failure when the non-history tiers alone exceed the prompt budget.
/// No section is ever silently dropped.
@Suite("Turn prompt overflow", .tags(.integration))
struct PromptOverflowTests {
    private func makeRuntime(
        model: MockLLMService,
        repository: InMemoryTimelineRuntimeRepository,
        customization: RuntimeCustomization = .default,
        maxOutputTokens: Int = 1
    ) -> PKRuntime {
        PKRuntime(configuration: .init(
            languageModel: model,
            persistence: .init(runtimeRepository: repository),
            runtime: .init(customization: customization),
            generationParameters: GenerationParameters(maxTokens: maxOutputTokens)
        ))
    }

    private func setContextWindow(_ tokens: Int, on model: MockLLMService) {
        var config = model.mockConfig
        config.activeProviderConfiguration.contextWindowTokens = tokens
        model.mockConfig = config
    }

    @Test("non-history tiers over the prompt budget fail preparation with a structured error")
    func nonHistoryOverflowFailsStructured() async throws {
        let model = MockLLMService()
        setContextWindow(1_200, on: model)
        let repository = InMemoryTimelineRuntimeRepository()
        let runtime = makeRuntime(model: model, repository: repository)

        let timeline = try await runtime.timelines.create(title: "Overflow")
        let longInstructions = String(repeating: "instruction ", count: 2_000)

        do {
            _ = try await timeline.startDirectTurn(
                "hello",
                context: DirectTurnContext(systemInstructions: longInstructions, contributor: .host)
            )
            Issue.record("Expected promptExceedsContextWindow")
        } catch let error as TurnError {
            guard case let .promptExceedsContextWindow(estimated, limit) = error else {
                Issue.record("Unexpected TurnError: \(error)")
                return
            }
            #expect(estimated > limit)
            #expect(limit == 1_200 - 1 - TurnEngine.Constants.providerOverhead)
        }
        // The provider was never asked to generate.
        #expect(model.mockClient.streamCallCount == 0)
    }

    @Test("a projection applies before the overflow check and keeps the Turn runnable")
    func projectionAppliesBeforeOverflowCheck() async throws {
        let model = MockLLMService()
        setContextWindow(4_096, on: model)
        let repository = InMemoryTimelineRuntimeRepository()
        let recorder = ProjectionRecorder()
        let source = RecordingProjectionSource(
            recorder: recorder,
            requirement: .optional,
            error: nil,
            makeProjection: { request in
                guard !request.messages.isEmpty else { return nil }
                return TurnHistoryProjection(
                    coveredMessageIDs: request.messages.map(\.id),
                    replacement: "PRIOR-CHECKPOINT",
                    firstRetainedMessageID: nil
                )
            }
        )
        let runtime = makeRuntime(
            model: model,
            repository: repository,
            customization: RuntimeCustomization(turnHistoryProjectionSource: source)
        )

        let timeline = try await runtime.timelines.create(title: "Projected")
        model.mockClient.nextResponse = String(repeating: "long answer ", count: 2_000)
        let firstTurn = try await timeline.startDirectTurn(
            "first question",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await firstTurn.events().collect()

        model.mockClient.nextResponse = "second answer"
        let secondTurn = try await timeline.startDirectTurn(
            "second question",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await secondTurn.events().collect()

        #expect(try await secondTurn.outcome() == .completed)
        let prompt = model.mockClient.lastMessages.map(\.content).joined(separator: "\n")
        #expect(prompt.contains("PRIOR-CHECKPOINT"))
        #expect(!prompt.contains("long answer"))
    }

    @Test("history trimming absorbs an over-budget history before the Turn fails")
    func historyTrimAbsorbsOverflow() async throws {
        let model = MockLLMService()
        setContextWindow(4_096, on: model)
        let repository = InMemoryTimelineRuntimeRepository()
        let runtime = makeRuntime(model: model, repository: repository)

        let timeline = try await runtime.timelines.create(title: "Trimmed")
        model.mockClient.nextResponse = String(repeating: "long answer ", count: 2_000)
        let firstTurn = try await timeline.startDirectTurn(
            "first question",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await firstTurn.events().collect()

        model.mockClient.nextResponse = "second answer"
        let secondTurn = try await timeline.startDirectTurn(
            "second question",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await secondTurn.events().collect()

        #expect(try await secondTurn.outcome() == .completed)
        let prompt = model.mockClient.lastMessages.map(\.content).joined(separator: "\n")
        // The oldest messages were dropped at a tool-transaction boundary instead of failing.
        #expect(!prompt.contains("long answer"))
        #expect(prompt.contains("second question"))
    }
}

private actor ProjectionRecorder {
    private(set) var requests: [TurnHistoryProjectionRequest] = []

    func record(_ request: TurnHistoryProjectionRequest) {
        requests.append(request)
    }
}

private struct RecordingProjectionSource: TurnHistoryProjectionSource {
    let recorder: ProjectionRecorder
    let requirement: TurnContextContributionRequirement
    let error: (any Error & Sendable)?
    let makeProjection: @Sendable (TurnHistoryProjectionRequest) -> TurnHistoryProjection?

    var failureRequirement: TurnContextContributionRequirement { requirement }

    func projection(for request: TurnHistoryProjectionRequest) async throws -> TurnHistoryProjection? {
        await recorder.record(request)
        if let error {
            throw error
        }
        return makeProjection(request)
    }
}
