import Testing
@testable import PKShared
import PKUtilities
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
            toolCallID: "call_1",
            name: "lookup_weather",
            error: "bad args"
        ))
        let completionEvent = ChatEvent.completion(.generationCompleted(
            message: Message(content: "done", role: .assistant),
            metadata: completionMeta
        ))
        let maxTurnsEvent = ChatEvent.maxTurnsReached()
        let deferredEvent = ChatEvent.deferredForExternalTool()

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
            case .toolCallError(let toolCallID, let name, let error):
                #expect(toolCallID == "call_1")
                #expect(name == "lookup_weather")
                #expect(error == "bad args")
            default:
                Issue.record("Expected nested error.toolCallError event")
            }
        default:
            Issue.record("Expected outer error event")
        }

        switch completionEvent {
        case .completion(let event):
            switch event {
            case .generationCompleted(let message, let metadata):
                #expect(message.content == "done")
                #expect(metadata.totalTokens == 42)
            default:
                Issue.record("Expected nested completion.generationCompleted event")
            }
        default:
            Issue.record("Expected outer completion event")
        }

        if case .completion(.maxTurnsReached) = maxTurnsEvent {
            // success
        } else {
            Issue.record("Expected completion.maxTurnsReached event, got \(maxTurnsEvent)")
        }

        if case .completion(.deferredForExternalTool) = deferredEvent {
            // success
        } else {
            Issue.record("Expected completion.deferredForExternalTool event, got \(deferredEvent)")
        }
    }

    @Test("Tool-call identifier APIs preserve legacy construction and wire keys")
    func toolCallIdentifierCompatibility() throws {
        let status = ToolExecutionStatus.executionError("bad args")
        let canonicalEvents: [ChatEvent] = [
            .toolProgress(toolCallID: "call_delta", status: status),
            .toolCallError(toolCallID: "call_error", name: "lookup", error: "bad args"),
            .toolCompleted(toolCallID: "call_completion", status: status),
        ]

        for event in canonicalEvents {
            let encoded = try JSONEncoder().encode(event)
            let json = try #require(String(data: encoded, encoding: .utf8))
            #expect(json.contains("\"toolCallId\""))
            #expect(!json.contains("\"toolCallID\""))

            let decoded = try JSONDecoder().decode(ChatEvent.self, from: encoded)
            switch decoded {
            case .delta(.toolExecution(let toolCallID, _)):
                #expect(toolCallID == "call_delta")
            case .error(.toolCallError(let toolCallID, _, _)):
                #expect(toolCallID == "call_error")
            case .completion(.toolExecution(let toolCallID, _)):
                #expect(toolCallID == "call_completion")
            default:
                Issue.record("Unexpected decoded event: \(decoded)")
            }
        }

        let legacyDelta = ChatEvent.delta(.toolExecution(
            toolCallId: "legacy_delta",
            status: status
        ))
        let legacyError = ChatEvent.error(.toolCallError(
            toolCallId: "legacy_error",
            name: "lookup",
            error: "bad args"
        ))
        let legacyCompletion = ChatEvent.completion(.toolExecution(
            toolCallId: "legacy_completion",
            status: status
        ))

        if case .delta(.toolExecution(let toolCallID, _)) = legacyDelta {
            #expect(toolCallID == "legacy_delta")
        } else {
            Issue.record("Legacy delta construction did not forward")
        }
        if case .error(.toolCallError(let toolCallID, _, _)) = legacyError {
            #expect(toolCallID == "legacy_error")
        } else {
            Issue.record("Legacy error construction did not forward")
        }
        if case .completion(.toolExecution(let toolCallID, _)) = legacyCompletion {
            #expect(toolCallID == "legacy_completion")
        } else {
            Issue.record("Legacy completion construction did not forward")
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
