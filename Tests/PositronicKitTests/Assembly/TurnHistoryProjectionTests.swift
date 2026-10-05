import Foundation
import PKContracts
import PKTestSupport
@testable import PositronicKit
import Testing

@Suite("Turn history projection", .tags(.integration))
struct TurnHistoryProjectionTests {
    // MARK: - Structural validation

    @Test("coverage must be a contiguous prefix")
    func coverageMustBeContiguousPrefix() throws {
        let messages = [
            Message(content: "one", role: .user),
            Message(content: "two", role: .assistant),
            Message(content: "three", role: .user),
        ]
        let projection = TurnHistoryProjection(
            coveredMessageIDs: [messages[1].id],
            replacement: "summary",
            firstRetainedMessageID: messages[2].id
        )

        #expect(throws: TurnHistoryProjectionError.self) {
            _ = try TurnHistoryProjectionValidator.apply(projection, to: messages, currentInputID: nil)
        }
    }

    @Test("coverage cannot split a tool transaction")
    func coverageCannotSplitToolTransaction() throws {
        let callID = "call-1"
        let messages = [
            Message(content: "question", role: .user),
            Message(content: "", role: .assistant, toolCalls: [ToolCall(id: callID, name: "lookup", arguments: [:])]),
            Message(content: "result", role: .tool, toolCallID: callID),
        ]
        let projection = TurnHistoryProjection(
            coveredMessageIDs: [messages[0].id, messages[1].id],
            replacement: "summary",
            firstRetainedMessageID: messages[2].id
        )

        #expect(throws: TurnHistoryProjectionError.self) {
            _ = try TurnHistoryProjectionValidator.apply(projection, to: messages, currentInputID: nil)
        }
    }

    @Test("a whole tool transaction may be covered")
    func wholeToolTransactionMayBeCovered() throws {
        let callID = "call-1"
        let messages = [
            Message(content: "question", role: .user),
            Message(content: "", role: .assistant, toolCalls: [ToolCall(id: callID, name: "lookup", arguments: [:])]),
            Message(content: "result", role: .tool, toolCallID: callID),
            Message(content: "follow-up", role: .user),
        ]
        let projection = TurnHistoryProjection(
            coveredMessageIDs: messages.prefix(3).map(\.id),
            replacement: "summary",
            firstRetainedMessageID: messages[3].id
        )

        let applied = try TurnHistoryProjectionValidator.apply(projection, to: messages, currentInputID: nil)
        #expect(applied.replacement == "summary")
        #expect(applied.retainedHistory.map(\.id) == [messages[3].id])
    }

    @Test("coverage cannot include the current input")
    func coverageCannotIncludeCurrentInput() throws {
        let messages = [Message(content: "old", role: .user)]
        let currentInput = Message(content: "now", role: .user)
        let projection = TurnHistoryProjection(
            coveredMessageIDs: [currentInput.id],
            replacement: "summary",
            firstRetainedMessageID: nil
        )

        #expect(throws: TurnHistoryProjectionError.self) {
            _ = try TurnHistoryProjectionValidator.apply(
                projection,
                to: messages,
                currentInputID: currentInput.id
            )
        }
    }

    @Test("first retained message must follow the covered prefix")
    func firstRetainedMustMatch() throws {
        let messages = [
            Message(content: "one", role: .user),
            Message(content: "two", role: .assistant),
        ]
        let projection = TurnHistoryProjection(
            coveredMessageIDs: [messages[0].id],
            replacement: "summary",
            firstRetainedMessageID: nil
        )

        #expect(throws: TurnHistoryProjectionError.self) {
            _ = try TurnHistoryProjectionValidator.apply(projection, to: messages, currentInputID: nil)
        }
    }

    // MARK: - Prompt integration

    @Test("a projection replaces the covered prefix in the provider prompt")
    func projectionReplacesCoveredPrefix() async throws {
        let model = MockLLMService()
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
                    replacement: "PRIOR-SUMMARY",
                    firstRetainedMessageID: nil
                )
            }
        )
        let kit = try await makeKit(
            model: model,
            repository: repository,
            customization: RuntimeCustomization(turnHistoryProjectionSource: source)
        )

        let timeline = try await kit.timelines.create(title: "Projection")
        model.mockClient.nextResponse = "first answer"
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

        let prompt = model.mockClient.lastMessages.map(\.content).joined(separator: "\n")
        #expect(prompt.contains("PRIOR-SUMMARY"))
        #expect(!prompt.contains("first question"))
        #expect(!prompt.contains("first answer"))
        #expect(prompt.contains("second question"))
        #expect(try await secondTurn.outcome() == .completed)

        let durable = try await repository.fetchMessages(for: timeline.id)
        #expect(durable.map(\.content) == ["first question", "first answer", "second question", "second answer"])
    }

    @Test("without a projection source raw history is sent unchanged")
    func withoutSourceRawHistoryIsSent() async throws {
        let model = MockLLMService()
        let repository = InMemoryTimelineRuntimeRepository()
        let kit = try await makeKit(
            model: model,
            repository: repository,
            customization: .default
        )

        let timeline = try await kit.timelines.create(title: "Raw history")
        model.mockClient.nextResponse = "first answer"
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

        let prompt = model.mockClient.lastMessages.map(\.content).joined(separator: "\n")
        #expect(prompt.contains("first question"))
        #expect(prompt.contains("first answer"))
        #expect(prompt.contains("second question"))
    }

    @Test("an optional source failure falls back to raw history with a notice")
    func optionalFailureFallsBackWithNotice() async throws {
        let model = MockLLMService()
        let repository = InMemoryTimelineRuntimeRepository()
        let recorder = ProjectionRecorder()
        let source = RecordingProjectionSource(
            recorder: recorder,
            requirement: .optional,
            error: ContextSourceFailure.unavailable,
            makeProjection: { _ in nil }
        )
        let kit = try await makeKit(
            model: model,
            repository: repository,
            customization: RuntimeCustomization(turnHistoryProjectionSource: source)
        )

        let timeline = try await kit.timelines.create(title: "Optional projection")
        model.mockClient.nextResponse = "first answer"
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
        let notices = try await repository.fetchNotices(turnID: secondTurn.id)
        #expect(notices.contains { $0.kind == TurnNoticeCode.historyProjectionFailed.rawValue })

        let prompt = model.mockClient.lastMessages.map(\.content).joined(separator: "\n")
        #expect(prompt.contains("first question"))
        #expect(prompt.contains("first answer"))
    }

    @Test("a required source failure aborts preparation")
    func requiredFailureAbortsPreparation() async throws {
        let model = MockLLMService()
        let repository = InMemoryTimelineRuntimeRepository()
        let recorder = ProjectionRecorder()
        let source = RecordingProjectionSource(
            recorder: recorder,
            requirement: .required,
            error: ContextSourceFailure.unavailable,
            makeProjection: { _ in nil }
        )
        let kit = try await makeKit(
            model: model,
            repository: repository,
            customization: RuntimeCustomization(turnHistoryProjectionSource: source)
        )

        let timeline = try await kit.timelines.create(title: "Required projection")
        await #expect(throws: TurnDegradationError.self) {
            _ = try await timeline.startDirectTurn(
                "must fail",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
        }
        #expect(model.mockClient.streamCallCount == 0)
    }

    @Test("invalid coverage is rejected structurally")
    func invalidCoverageIsRejected() async throws {
        let model = MockLLMService()
        let repository = InMemoryTimelineRuntimeRepository()
        let recorder = ProjectionRecorder()
        let source = RecordingProjectionSource(
            recorder: recorder,
            requirement: .optional,
            error: nil,
            makeProjection: { request in
                // Cover only the last offered message, which is never a contiguous prefix.
                guard let last = request.messages.last, request.messages.count > 1 else { return nil }
                return TurnHistoryProjection(
                    coveredMessageIDs: [last.id],
                    replacement: "summary",
                    firstRetainedMessageID: nil
                )
            }
        )
        let kit = try await makeKit(
            model: model,
            repository: repository,
            customization: RuntimeCustomization(turnHistoryProjectionSource: source)
        )

        let timeline = try await kit.timelines.create(title: "Invalid coverage")
        model.mockClient.nextResponse = "first answer"
        let firstTurn = try await timeline.startDirectTurn(
            "first question",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await firstTurn.events().collect()

        await #expect(throws: TurnHistoryProjectionError.self) {
            _ = try await timeline.startDirectTurn(
                "second question",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
        }
    }

    @Test("a projection change is a deliberate prefix reset")
    func projectionChangeResetsStablePrefix() async throws {
        let model = MockLLMService()
        let repository = InMemoryTimelineRuntimeRepository()
        let recorder = ProjectionRecorder()
        let source = RecordingProjectionSource(
            recorder: recorder,
            requirement: .optional,
            error: nil,
            makeProjection: { request in
                guard !request.messages.isEmpty else { return nil }
                let marker = request.messages.count > 2 ? "SECOND-SUMMARY" : "FIRST-SUMMARY"
                return TurnHistoryProjection(
                    coveredMessageIDs: request.messages.map(\.id),
                    replacement: marker,
                    firstRetainedMessageID: nil
                )
            }
        )
        let kit = try await makeKit(
            model: model,
            repository: repository,
            customization: RuntimeCustomization(turnHistoryProjectionSource: source)
        )

        let timeline = try await kit.timelines.create(title: "Prefix reset")
        for response in ["answer one", "answer two"] {
            model.mockClient.nextResponse = response
            let turn = try await timeline.startDirectTurn(
                "question \(response)",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
            _ = await turn.events().collect()
        }

        // The third turn covers a longer prefix, so the projection section content changes and
        // prompt history must record a change rather than an inconsistency.
        model.mockClient.nextResponse = "answer three"
        let thirdTurn = try await timeline.startDirectTurn(
            "question three",
            context: DirectTurnContext(systemInstructions: "", contributor: .host)
        )
        _ = await thirdTurn.events().collect()

        #expect(try await thirdTurn.outcome() == .completed)
        let prompt = model.mockClient.lastMessages.map(\.content).joined(separator: "\n")
        #expect(prompt.contains("SECOND-SUMMARY"))
    }

    private func makeKit(
        model: MockLLMService,
        repository: InMemoryTimelineRuntimeRepository,
        customization: RuntimeCustomization
    ) async throws -> PKRuntime {
        PKRuntime(configuration: .init(
            languageModel: model,
            persistence: .init(runtimeRepository: repository),
            runtime: .init(customization: customization)
        ))
    }
}

private enum ContextSourceFailure: Error, Sendable {
    case unavailable
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
