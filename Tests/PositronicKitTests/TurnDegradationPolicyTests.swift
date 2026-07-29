import Foundation
@testable import PKShared
import PKUtilities
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite(.serialized) @MainActor
struct TurnDegradationPolicyTests {
    @Test("required context failure aborts before provider generation")
    func requiredContextFailureAbortsBeforeGeneration() async throws {
        let persistence = MockPersistenceService()
        let model = MockLLMService()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: URL(fileURLWithPath: "/tmp/pkrr-022"),
            workspaceCreator: MockWorkspaceCreator()
        )
        let timeline = Timeline(title: "degradation")
        try await persistence.saveTimeline(timeline)
        try await timelineManager.hydrateTimeline(id: timeline.id)
        let builder = try #require(await timelineManager.getTurnBriefingBuilder(for: timeline.id))
        let failingPipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent>(stages: [ThrowingContextStage()])
        let engine = ChatEngine(
            dependencies: .init(
                timelineManager: timelineManager,
                agentInstanceStore: persistence,
                requestOriginStore: persistence,
                messageStore: persistence,
                llmService: model,
                toolRouter: ToolRouter(timelineManager: timelineManager, messageStore: persistence),
                chatTurnPlugins: []
            )
        )

        do {
            _ = try await engine.execute(
                timelineId: timeline.id,
                message: "needs context",
                tools: [],
                turnBriefingBuilder: builder,
                contextPipeline: failingPipeline
            )
            Issue.record("Expected required context failure")
        } catch let error as TurnDegradationError {
            #expect(error.diagnostic.dependency == .context)
            #expect(ChatEvent.ErrorIdentity.extracting(from: error)?.code == 9010)
        }

        #expect(model.mockClient.streamCallCount == 0)
    }

    @Test("continueWithWarnings emits structured context diagnostics")
    func optionalContextFailureEmitsDiagnostic() async throws {
        let persistence = MockPersistenceService()
        let model = MockLLMService()
        let timelineManager = TimelineManager(
            stores: .init(
                timelineStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: URL(fileURLWithPath: "/tmp/pkrr-022"),
            workspaceCreator: MockWorkspaceCreator()
        )
        let timeline = Timeline(title: "degradation")
        try await persistence.saveTimeline(timeline)
        try await timelineManager.hydrateTimeline(id: timeline.id)
        let builder = try #require(await timelineManager.getTurnBriefingBuilder(for: timeline.id))
        model.mockClient.nextResponse = "continued"
        let engine = ChatEngine(
            dependencies: .init(
                timelineManager: timelineManager,
                agentInstanceStore: persistence,
                requestOriginStore: persistence,
                messageStore: persistence,
                llmService: model,
                toolRouter: ToolRouter(timelineManager: timelineManager, messageStore: persistence),
                chatTurnPlugins: [],
                degradationPolicy: .continueWithWarnings
            )
        )

        let stream = try await engine.execute(
            timelineId: timeline.id,
            message: "optional context",
            tools: [],
            turnBriefingBuilder: builder,
            contextPipeline: Pipeline(stages: [ThrowingContextStage()])
        )
        var diagnostics: [TurnDiagnostic] = []
        for try await event in stream {
            if case let .meta(.generationContext(metadata)) = event {
                diagnostics = metadata.diagnostics
            }
        }

        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].dependency == .context)
        #expect(diagnostics[0].errorIdentity?.code == 2002)
    }

    private struct ThrowingContextStage: PipelineStage {
        let id = "ThrowingContextStage"

        func process(_: ContextPipelineContext) async throws -> AsyncThrowingStream<ContextGatheringEvent, Error> {
            throw TurnBriefingBuilderError.persistenceFailed(FailingStoreError.fetchFailed)
        }
    }
}
