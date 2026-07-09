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
        let toolDeltaEvent = ChatEvent.delta(.toolCall(delta: ToolCallDelta(
            index: 0,
            id: "call_1",
            name: "lookup_weather",
            arguments: "{}"
        )))
        let toolErrorEvent = ChatEvent.error(.toolCallError(
            toolCallId: "call_1",
            name: "lookup_weather",
            error: "bad args"
        ))
        let metaCompletionEvent = ChatEvent.meta(.generationCompleted(
            message: Message(content: "done", role: .assistant),
            metadata: completionMeta
        ))
        let completionEvent = ChatEvent.completion(.streamCompleted)

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

    @Test
    func completedEmptyEventRoundTripsThroughCodable() throws {
        let event = ChatEvent.completedEmpty(finishReason: "stop")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(event)
        let decoded = try decoder.decode(ChatEvent.self, from: data)

        if case let .completion(.completedEmpty(finishReason: finishReason)) = decoded {
            #expect(finishReason == "stop")
        } else {
            Issue.record("Expected decoded .completedEmpty event, got \(decoded)")
        }
    }

    // MARK: - Error Identity (STAB-6)

    @Test
    func errorFromPKErrorCarriesStructuredIdentity() throws {
        let event = ChatEvent.error(ToolError.permissionDenied("rm"))

        if case let .error(.error(message: message, identity: identity)) = event {
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

        if case let .error(.error(message: message, identity: identity)) = event {
            #expect(identity == nil)
            #expect(message == "denied by upstream policy")
        } else {
            Issue.record("Expected .error(message:, identity:), got \(event)")
        }
    }

    @Test
    func errorFromStringCarriesNilIdentity() throws {
        let event = ChatEvent.error("boom")

        if case let .error(.error(message: message, identity: identity)) = event {
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

        if case let .error(.error(message: _, identity: identity)) = decoded {
            #expect(identity == ChatEvent.ErrorIdentity(domain: PKErrorDomain.tool, code: 210))
        } else {
            Issue.record("Expected decoded .error event, got \(decoded)")
        }
    }

    @Test
    func blockedIdentityContractRecognizesKnownBlockedErrors() {
        // Blocked-error classification now lives on PKError.isBlocked, so we verify
        // via ErrorIdentity.extracting(from:) with actual error instances rather than
        // hand-listed (domain, code) pairs. WorkspaceError.accessDenied (workspace:3002)
        // is covered in PositronicKitTests since WorkspaceError lives in PositronicKit.
        let blockedErrors: [Error] = [
            ToolError.permissionDenied("rm"),
            ToolError.attachedToolsDisallowedOnPrivateTimeline,
            PathSanitizer.PathError.accessDenied("/etc/passwd"),
        ]
        for error in blockedErrors {
            let identity = ChatEvent.ErrorIdentity.extracting(from: error)
            #expect(identity?.isBlocked == true, "Expected \(String(describing: identity)) to be blocked")
        }

        let notBlockedErrors: [Error] = [
            ToolError.executionFailed("boom"),
            ToolError.toolNotFound("foo"),
            PathSanitizer.PathError.invalidPath("bad/path"),
        ]
        for error in notBlockedErrors {
            let identity = ChatEvent.ErrorIdentity.extracting(from: error)
            #expect(identity?.isBlocked == false, "Expected \(String(describing: identity)) to NOT be blocked")
        }
    }

    @Test
    func directlyConstructedIdentityDefaultsToNotBlocked() {
        // Identities constructed directly (not via extracting) default isBlocked to false
        // since they are not derived from a concrete PKError.
        let identity = ChatEvent.ErrorIdentity(domain: PKErrorDomain.tool, code: 210)
        #expect(!identity.isBlocked)
    }
}
