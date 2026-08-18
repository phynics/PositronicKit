import ErrorKit
import Foundation
import Logging
import struct JSONSchema.Schema
import JSONSchemaBuilder
import PKShared
import PKUtilities

/// Strict utility-generation operations.
///
/// Failures propagate to the caller so policy stays at the boundary that owns it (for
/// example, `ThreadArchiver`'s title fallback). The compatibility surface
/// ``BestEffortLLMUtilities`` re-introduces the old log-and-return-default behavior for
/// `LLMUtilityClient` protocol conformance.
struct LLMUtilityGenerator {
    private let streamClient: any LLMStreamClient

    init(streamClient: any LLMStreamClient) {
        self.streamClient = streamClient
    }

    /// Generates tags/keywords for the given text, throwing on failure.
    func generateTags(for text: String) async throws -> [String] {
        let directive = UtilityGenerationDirective.tags(text: text)
        let payload = try await send(directive)
        return directive.map(payload)
    }

    /// Generates a concise conversation title, throwing on failure.
    ///
    /// An empty message list is not a provider failure: it maps to the documented
    /// `"New Conversation"` default without invoking the model.
    func generateTitle(for messages: [Message]) async throws -> String {
        guard !messages.isEmpty else {
            return "New Conversation"
        }
        let transcript = messages.map { "[\($0.role.rawValue.uppercased())] \($0.content)" }.joined(
            separator: "\n\n"
        )
        let directive = UtilityGenerationDirective.title(transcript: transcript)
        let payload = try await send(directive)
        return directive.map(payload)
    }

    /// Evaluates which recalled memories were actually helpful, throwing on failure.
    ///
    /// An empty memory list maps to `[:]` without invoking the model.
    func evaluateRecallPerformance(
        transcript: String,
        recalledMemories: [Memory]
    ) async throws -> [String: Double] {
        guard !recalledMemories.isEmpty else {
            return [:]
        }
        let directive = UtilityGenerationDirective.recallPerformance(
            transcript: transcript,
            recalledMemories: recalledMemories
        )
        let payload = try await send(directive)
        return directive.map(payload)
    }

    private func send<Payload: Decodable & Sendable, Output: Sendable>(
        _ directive: UtilityGenerationDirective<Payload, Output>
    ) async throws -> Payload {
        try await streamClient.sendStructured(
            directive.prompt,
            structuredOutput: directive.structuredOutput,
            as: directive.payloadType,
            generationParameters: nil,
            modelTier: .utility
        )
    }
}

/// Best-effort utility operations that log failures and return documented defaults.
///
/// Backs the `LLMUtilityClient` compatibility surface during the current major version.
struct BestEffortLLMUtilities {
    private let streamClient: any LLMStreamClient
    private let logger: Logger

    init(streamClient: any LLMStreamClient, logger: Logger) {
        self.streamClient = streamClient
        self.logger = logger
    }

    func generateTags(for text: String) async -> [String] {
        do {
            return try await LLMUtilityGenerator(streamClient: streamClient).generateTags(for: text)
        } catch {
            logger.error("Failed to generate tags: \(ErrorKit.userFriendlyMessage(for: error))")
            return []
        }
    }

    func generateTitle(for messages: [Message]) async -> String {
        do {
            return try await LLMUtilityGenerator(streamClient: streamClient).generateTitle(for: messages)
        } catch {
            logger.error("Failed to generate title: \(ErrorKit.userFriendlyMessage(for: error))")
            return "New Conversation"
        }
    }

    func evaluateRecallPerformance(
        transcript: String,
        recalledMemories: [Memory]
    ) async -> [String: Double] {
        do {
            return try await LLMUtilityGenerator(streamClient: streamClient).evaluateRecallPerformance(
                transcript: transcript,
                recalledMemories: recalledMemories
            )
        } catch {
            logger.error("Failed to evaluate recall: \(ErrorKit.userFriendlyMessage(for: error))")
            return [:]
        }
    }
}

private struct UtilityGenerationDirective<Payload: Decodable & Sendable, Output: Sendable> {
    let logLabel: String
    let prompt: String
    let structuredOutput: StructuredOutputRequest
    let payloadType: Payload.Type
    let defaultValue: Output
    let map: @Sendable (Payload) -> Output
}

private extension UtilityGenerationDirective where Payload == LLMTagResponse, Output == [String] {
    static func tags(text: String) -> Self {
        Self(
            logLabel: "generate tags",
            prompt: """
            Extract 3-5 relevant keywords or tags from the following text.
            Return ONLY a JSON object with a key "tags" containing an array of strings.

            Text:
            \(text)
            """,
            structuredOutput: .jsonSchema(StructuredOutputSchema(
                name: "llm_tags",
                description: "A structured list of tags extracted from the provided text.",
                schema: LLMTagResponse.schema.definition()
            )),
            payloadType: LLMTagResponse.self,
            defaultValue: [],
            map: { $0.tags.map { $0.lowercased() } }
        )
    }
}

private extension UtilityGenerationDirective where Payload == LLMTitleResponse, Output == String {
    static func title(transcript: String) -> Self {
        Self(
            logLabel: "generate title",
            prompt: """
            Based on the following conversation transcript, generate a concise, descriptive title (maximum 6 words).
            Return ONLY a JSON object with a key "title" containing the title text, with no surrounding quotes or additional formatting.

            TRANSCRIPT:
            \(transcript)
            """,
            structuredOutput: .jsonSchema(StructuredOutputSchema(
                name: "llm_title",
                description: "A concise conversation title.",
                schema: LLMTitleResponse.schema.definition()
            )),
            payloadType: LLMTitleResponse.self,
            defaultValue: "New Conversation",
            map: { payload in
                let title = payload.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")
                return title.isEmpty ? "New Conversation" : title
            }
        )
    }
}

private extension UtilityGenerationDirective where Payload == [String: Double], Output == [String: Double] {
    static let recallPerformanceSchema = try! Schema( // swiftlint:disable:this force_try
        instance: #"{"type":"object","additionalProperties":{"type":"number","minimum":-1.0,"maximum":1.0}}"#
    )

    static func recallPerformance(transcript: String, recalledMemories: [Memory]) -> Self {
        let memoriesText = recalledMemories.map {
            "- ID: \($0.id.uuidString)\n  Title: \($0.title)\n  Content: \($0.content)"
        }.joined(separator: "\n\n")

        return Self(
            logLabel: "evaluate recall",
            prompt: """
            Analyze the following conversation transcript and the list of \
            recalled memories that were provided to you as context.
            Determine for EACH memory if it was actually useful for answering \
            the user's questions or providing relevant context.

            RECALLED MEMORIES:
            \(memoriesText)

            TRANSCRIPT:
            \(transcript)

            Return ONLY a JSON object where keys are memory IDs and values \
            are helpfulness scores (numbers between -1.0 and 1.0):
            1.0: Extremely helpful, directly used to answer.
            0.5: Somewhat helpful, provided good context.
            0.0: Neutral, didn't hurt but wasn't used.
            -0.5: Irrelevant, slightly off-topic.
            -1.0: Completely irrelevant or misleading.
            """,
            structuredOutput: .jsonSchema(StructuredOutputSchema(
                name: "recall_performance",
                description: "A map of memory IDs to helpfulness scores between -1.0 and 1.0.",
                schema: recallPerformanceSchema
            )),
            payloadType: [String: Double].self,
            defaultValue: [:],
            map: { $0 }
        )
    }
}

@Schemable
struct LLMTagResponse: Codable {
    let tags: [String]
}

@Schemable
struct LLMTitleResponse: Codable {
    let title: String
}
