import Testing
@testable import PKShared
import Foundation
import ErrorKit

@Suite final class ChatEventTests {
    @Test

    func testGenerationCancelledEvent() throws {
        // This should fail to compile after the rename or if I use the new name now
        // But for TDD, I should write something that expects 'generationCancelled'
        let event = ChatEvent.generationCancelled()

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChatEvent.self, from: data)

        if case let .error(errorEvent) = decoded {
            if case .generationCancelled = errorEvent {
                // Success
            } else {
                Issue.record("Expected .generationCancelled, got \(errorEvent)")
            }
        } else {
            Issue.record("Expected .error, got \(decoded)")
        }
    }

    @Test
    func usageGuideEventPatternMatchesCurrentShape() {
        let completionMeta = APIResponseMetadata(totalTokens: 42)
        let toolDeltaEvent = ChatEvent.delta(event: .toolCall(delta: ToolCallDelta(
            index: 0,
            id: "call_1",
            name: "lookup_weather",
            arguments: "{}"
        )))
        let toolErrorEvent = ChatEvent.error(event: .toolCallError(
            toolCallId: "call_1",
            name: "lookup_weather",
            error: "bad args"
        ))
        let metaCompletionEvent = ChatEvent.meta(event: .generationCompleted(
            message: Message(content: "done", role: .assistant),
            metadata: completionMeta
        ))
        let completionEvent = ChatEvent.completion(event: .streamCompleted)

        switch toolDeltaEvent {
        case .delta(let event):
            switch event {
            case .toolCall(let delta):
                #expect(delta.id == "call_1")
                #expect(delta.name == "lookup_weather")
            default:
                Issue.record("Expected nested delta.toolCall event")
            }
        default:
            Issue.record("Expected outer delta event")
        }

        switch toolErrorEvent {
        case .error(let event):
            switch event {
            case .toolCallError(let toolCallId, let name, let error):
                #expect(toolCallId == "call_1")
                #expect(name == "lookup_weather")
                #expect(error == "bad args")
            default:
                Issue.record("Expected nested error.toolCallError event")
            }
        default:
            Issue.record("Expected outer error event")
        }

        switch metaCompletionEvent {
        case .meta(let event):
            switch event {
            case .generationCompleted(let message, let metadata):
                #expect(message.content == "done")
                #expect(metadata.totalTokens == 42)
            default:
                Issue.record("Expected nested meta.generationCompleted event")
            }
        default:
            Issue.record("Expected outer meta event")
        }

        switch completionEvent {
        case .completion(let event):
            switch event {
            case .streamCompleted:
                break
            default:
                Issue.record("Expected nested completion.streamCompleted event")
            }
        default:
            Issue.record("Expected outer completion event")
        }
    }

    // MARK: - Error Identity (STAB-6)

    @Test
    func errorFromPKErrorCarriesStructuredIdentity() throws {
        let event = ChatEvent.error(ToolError.permissionDenied("rm"))

        if case let .error(event: .error(message: message, identity: identity)) = event {
            #expect(identity == ChatEvent.ErrorIdentity(domain: PKErrorDomain.tool, code: 210))
            // STAB-4 contract preserved: message is the user-friendly string, no [domain:code] prefix.
            #expect(message == "The tool 'rm' requires permission and was not approved.")
            #expect(!message.contains("[\(PKErrorDomain.tool):210]"))
        } else {
            Issue.record("Expected .error(message:, identity:), got \(event)")
        }
    }

    @Test
    func errorFromPlainErrorCarriesNilIdentity() throws {
        struct ProviderError: Error, LocalizedError {
            var errorDescription: String? { "denied by upstream policy" }
        }
        let event = ChatEvent.error(ProviderError())

        if case let .error(event: .error(message: message, identity: identity)) = event {
            #expect(identity == nil)
            #expect(message == "denied by upstream policy")
        } else {
            Issue.record("Expected .error(message:, identity:), got \(event)")
        }
    }

    @Test
    func errorFromStringCarriesNilIdentity() throws {
        let event = ChatEvent.error("boom")

        if case let .error(event: .error(message: message, identity: identity)) = event {
            #expect(identity == nil)
            #expect(message == "boom")
        } else {
            Issue.record("Expected .error(message:, identity:), got \(event)")
        }
    }

    @Test
    func errorIdentityRoundTripsThroughCodable() throws {
        let event = ChatEvent.error(ToolError.permissionDenied("rm"))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(event)
        let decoded = try decoder.decode(ChatEvent.self, from: data)

        if case let .error(event: .error(message: _, identity: identity)) = decoded {
            #expect(identity == ChatEvent.ErrorIdentity(domain: PKErrorDomain.tool, code: 210))
        } else {
            Issue.record("Expected decoded .error event, got \(decoded)")
        }
    }

    @Test
    func blockedIdentityContractRecognizesKnownBlockedCodes() {
        let blocked: [ChatEvent.ErrorIdentity] = [
            .init(domain: PKErrorDomain.tool, code: 210),
            .init(domain: PKErrorDomain.tool, code: 207),
            .init(domain: PKErrorDomain.filesystem, code: 101),
            .init(domain: PKErrorDomain.workspace, code: 3002),
        ]
        for identity in blocked {
            #expect(identity.isBlocked, "Expected \(identity) to be blocked")
        }

        let notBlocked: [ChatEvent.ErrorIdentity] = [
            .init(domain: PKErrorDomain.tool, code: 203),
            .init(domain: PKErrorDomain.tool, code: 204),
        ]
        for identity in notBlocked {
            #expect(!identity.isBlocked, "Expected \(identity) to NOT be blocked")
        }
    }
}
