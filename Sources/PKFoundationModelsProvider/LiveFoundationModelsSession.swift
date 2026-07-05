import Foundation
import PKShared

#if canImport(FoundationModels)
    import FoundationModels

    /// Production `FoundationModelsSessionProtocol` implementation: drives a real
    /// `LanguageModelSession` and translates its `ResponseStream<String>` snapshots plus
    /// transcript into `FoundationModelsSessionEvent`s (PKPOST-003).
    ///
    /// Confirmed against the SDK (macOS 26.5): `LanguageModelSession.streamResponse(to:)`
    /// snapshots are *cumulative* (each snapshot is the full response so far, not a delta), and
    /// the framework executes any registered `Tool.call(arguments:)` itself while producing the
    /// response — tool calls/outputs are only observable after the fact via `session.transcript`,
    /// not as an intermediate "please execute this" signal like the HTTP-family adapters. This
    /// wrapper accounts for both: it diffs snapshots into deltas, and emits `toolCall`/
    /// `toolOutput` events by diffing the transcript before/after the turn.
    @available(macOS 26.0, *)
    struct LiveFoundationModelsSession: FoundationModelsSessionProtocol {
        private let session: LanguageModelSession

        init(instructions: String?, tools: [any FoundationModels.Tool] = []) {
            session = LanguageModelSession(tools: tools, instructions: instructions)
        }

        init(bridging tools: [AnyTool], instructions: String?) {
            self.init(instructions: instructions, tools: tools.map { PKBridgedFMTool(wrapped: $0) })
        }

        func streamTurn(prompt: String) -> AsyncThrowingStream<FoundationModelsSessionEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    if let availabilityError = FoundationModelsAvailabilityError(
                        availability: SystemLanguageModel.default.availability
                    ) {
                        continuation.finish(throwing: availabilityError)
                        return
                    }

                    let transcriptCountBefore = session.transcript.count
                    var previousText = ""
                    do {
                        let stream = session.streamResponse(to: prompt)
                        for try await snapshot in stream {
                            if Task.isCancelled { break }
                            let current = snapshot.content
                            if current.count > previousText.count, current.hasPrefix(previousText) {
                                let delta = String(current.dropFirst(previousText.count))
                                if !delta.isEmpty {
                                    continuation.yield(.textDelta(delta))
                                }
                            } else if current != previousText {
                                // Non-prefix revision (rare): re-emit the full new content rather
                                // than lose it. Consumers see a slightly larger delta, not
                                // dropped text.
                                continuation.yield(.textDelta(current))
                            }
                            previousText = current
                        }

                        emitToolEvents(from: transcriptCountBefore, into: continuation)
                        continuation.yield(.finished(.stop))
                        continuation.finish()
                    } catch let error as LanguageModelSession.GenerationError {
                        emitToolEvents(from: transcriptCountBefore, into: continuation)
                        continuation.finish(throwing: FoundationModelsGenerationError(error))
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// Emits `toolCall`/`toolOutput` events for any tool activity recorded in the transcript
        /// during this turn (entries added since `transcriptCountBefore`).
        private func emitToolEvents(
            from transcriptCountBefore: Int,
            into continuation: AsyncThrowingStream<FoundationModelsSessionEvent, Error>.Continuation
        ) {
            let entries = session.transcript
            guard transcriptCountBefore < entries.count else { return }
            for index in transcriptCountBefore ..< entries.count {
                switch entries[index] {
                case let .toolCalls(calls):
                    for call in calls {
                        let argumentsJSON = call.arguments.jsonString
                        continuation.yield(.toolCall(id: call.id, name: call.toolName, argumentsJSON: argumentsJSON))
                    }
                case let .toolOutput(output):
                    let text = output.segments.compactMap { segment -> String? in
                        if case let .text(textSegment) = segment { return textSegment.content }
                        return nil
                    }.joined()
                    continuation.yield(.toolOutput(id: output.id, name: output.toolName, output: text))
                default:
                    continue
                }
            }
        }
    }

    /// Maps `LanguageModelSession.GenerationError` onto a typed `PKError` (PKR-13-style
    /// termination-outcome mapping, applied to the framework's guardrail/context-window/decoding
    /// failure vocabulary rather than a wire `finish_reason` string, since these arrive as thrown
    /// errors from the stream, not as a terminal chunk).
    public struct FoundationModelsGenerationError: PKError, Equatable {
        public enum Kind: Sendable, Equatable {
            case exceededContextWindowSize
            case guardrailViolation
            case unsupportedGuide
            case unsupportedLanguageOrLocale
            case decodingFailure
            case rateLimited
            case concurrentRequests
            case assetsUnavailable
            case refusal
            case other(String)
        }

        public let kind: Kind
        public let debugDescription: String

        @available(macOS 26.0, *)
        init(_ error: LanguageModelSession.GenerationError) {
            switch error {
            case let .exceededContextWindowSize(context):
                kind = .exceededContextWindowSize
                debugDescription = context.debugDescription
            case let .guardrailViolation(context):
                kind = .guardrailViolation
                debugDescription = context.debugDescription
            case let .unsupportedGuide(context):
                kind = .unsupportedGuide
                debugDescription = context.debugDescription
            case let .unsupportedLanguageOrLocale(context):
                kind = .unsupportedLanguageOrLocale
                debugDescription = context.debugDescription
            case let .decodingFailure(context):
                kind = .decodingFailure
                debugDescription = context.debugDescription
            case let .rateLimited(context):
                kind = .rateLimited
                debugDescription = context.debugDescription
            case let .concurrentRequests(context):
                kind = .concurrentRequests
                debugDescription = context.debugDescription
            case let .assetsUnavailable(context):
                kind = .assetsUnavailable
                debugDescription = context.debugDescription
            case let .refusal(_, context):
                kind = .refusal
                debugDescription = context.debugDescription
            @unknown default:
                kind = .other(String(describing: error))
                debugDescription = String(describing: error)
            }
        }

        public var errorDomain: String {
            PKErrorDomain.llm
        }

        public var errorCode: Int {
            switch kind {
            case .exceededContextWindowSize: return 2101
            case .guardrailViolation: return 2102
            case .unsupportedGuide: return 2103
            case .unsupportedLanguageOrLocale: return 2104
            case .decodingFailure: return 2105
            case .rateLimited: return 2106
            case .concurrentRequests: return 2107
            case .assetsUnavailable: return 2108
            case .refusal: return 2109
            case .other: return 2199
            }
        }

        public var userFriendlyMessage: String {
            switch kind {
            case .exceededContextWindowSize:
                return "The conversation is too long for the on-device model's context window. Start a new conversation or shorten it."
            case .guardrailViolation:
                return "The on-device model declined to respond because the request may violate its content guidelines."
            case .unsupportedGuide:
                return "The on-device model does not support one of the requested generation constraints."
            case .unsupportedLanguageOrLocale:
                return "The on-device model does not support the requested language or locale."
            case .decodingFailure:
                return "The on-device model produced a response that could not be decoded."
            case .rateLimited:
                return "The on-device model is temporarily rate-limited. Try again shortly."
            case .concurrentRequests:
                return "The on-device model is already handling another request for this session."
            case .assetsUnavailable:
                return "The on-device model's assets are unavailable."
            case .refusal:
                return "The on-device model declined to respond to this request."
            case let .other(reason):
                return "The on-device model failed: \(reason)"
            }
        }

        /// Maps this termination outcome onto the shared `FinishReason` vocabulary (PKR-13).
        public var finishReason: FinishReason {
            switch kind {
            case .guardrailViolation, .refusal:
                return .contentFilter
            case .exceededContextWindowSize:
                return .length
            default:
                return .other(debugDescription)
            }
        }
    }
#endif
