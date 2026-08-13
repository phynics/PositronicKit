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
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: URL(fileURLWithPath: "/tmp/pkrr-022"),
            workspaceCreator: MockWorkspaceCreator()
        )
        let thread = Thread(title: "degradation")
        try await persistence.saveThread(thread)
        try await threadManager.hydrateThread(id: thread.id)
        let builder = try #require(await threadManager.getTurnBriefingBuilder(for: thread.id))
        let failingPipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent>(stages: [ThrowingContextStage()])
        let engine = ChatEngine(
            dependencies: .init(
                threadManager: threadManager,
                agentInstanceStore: persistence,
                requestOriginStore: persistence,
                messageStore: persistence,
                llmService: model,
                toolRouter: ToolRouter(threadManager: threadManager, messageStore: persistence),
                chatTurnPlugins: []
            )
        )

        do {
            _ = try await engine.execute(
                threadID: thread.id,
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
        let threadManager = ThreadManager(
            stores: .init(
                threadStore: persistence,
                messageStore: persistence,
                workspaceStore: persistence,
                toolPersistence: persistence
            ),
            workspaceRoot: URL(fileURLWithPath: "/tmp/pkrr-022"),
            workspaceCreator: MockWorkspaceCreator()
        )
        let thread = Thread(title: "degradation")
        try await persistence.saveThread(thread)
        try await threadManager.hydrateThread(id: thread.id)
        let builder = try #require(await threadManager.getTurnBriefingBuilder(for: thread.id))
        model.mockClient.nextResponse = "continued"
        let engine = ChatEngine(
            dependencies: .init(
                threadManager: threadManager,
                agentInstanceStore: persistence,
                requestOriginStore: persistence,
                messageStore: persistence,
                llmService: model,
                toolRouter: ToolRouter(threadManager: threadManager, messageStore: persistence),
                chatTurnPlugins: [],
                degradationPolicy: .continueWithWarnings
            )
        )

        let stream = try await engine.execute(
            threadID: thread.id,
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
