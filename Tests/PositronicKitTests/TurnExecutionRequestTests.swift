import Foundation
import PKContracts
@testable import PositronicKit
import Testing

@Suite("Turn execution request")
struct TurnExecutionRequestTests {
    @Test("normalization keeps the public request and resolves facade defaults once")
    func resolvesFacadeDefaults() {
        let requestID = UUID()
        let defaults = GenerationParameters(temperature: 0.25, maxTokens: 512)
        let request = TurnRequest(
            threadID: UUID(),
            requestID: requestID,
            message: "Hello"
        )

        let executionRequest = TurnExecutionRequest(
            request,
            defaultGenerationParameters: defaults,
            executionKind: .direct,
            contributors: [.host]
        )

        #expect(executionRequest.request.requestID == requestID)
        #expect(executionRequest.request.messageContent == request.messageContent)
        #expect(executionRequest.requestID == requestID)
        #expect(executionRequest.generationParameters == defaults)
        #expect(executionRequest.context.kind == .direct)
        #expect(executionRequest.context.contributors == [.host])
    }

    @Test("idempotency fingerprints use effective generation parameters")
    func fingerprintsEffectiveGenerationParameters() {
        let threadID = UUID()
        let requestID = UUID()
        let effective = GenerationParameters(temperature: 0.5, maxTokens: 256)
        let inherited = TurnExecutionRequest(
            TurnRequest(threadID: threadID, requestID: requestID, message: "Hello"),
            defaultGenerationParameters: effective,
            executionKind: .direct
        )
        let explicit = TurnExecutionRequest(
            TurnRequest(
                threadID: threadID,
                requestID: requestID,
                message: "Hello",
                generationParameters: effective
            ),
            executionKind: .direct
        )
        let changed = TurnExecutionRequest(
            TurnRequest(threadID: threadID, requestID: requestID, message: "Hello"),
            defaultGenerationParameters: GenerationParameters(temperature: 0.75, maxTokens: 256),
            executionKind: .direct
        )

        #expect(inherited.callerIntentFingerprint == explicit.callerIntentFingerprint)
        #expect(inherited.callerIntentFingerprint != changed.callerIntentFingerprint)
    }
}
