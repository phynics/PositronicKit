import ErrorKit
import Foundation
import struct JSONSchema.Schema
import JSONSchemaBuilder
import Logging
import PKShared
import PKUtilities

public extension LLMUtilityClient where Self: LLMStreamClient {
    /// Generate tags/keywords for a given text using the LLM
    func generateTags(for text: String) async throws -> [String] {
        await runUtilityGeneration(
            UtilityGenerationDirective.tags(text: text),
            logger: utilityGenerationLogger
        )
    }

    /// Generate a concise title for a conversation
    func generateTitle(for messages: [Message]) async throws -> String {
        guard !messages.isEmpty else {
            return "New Conversation"
        }

        let transcript = messages.map { "[\($0.role.rawValue.uppercased())] \($0.content)" }.joined(
            separator: "\n\n"
        )

        return await runUtilityGeneration(
            UtilityGenerationDirective.title(transcript: transcript),
            logger: utilityGenerationLogger
        )
    }

    /// Evaluate which recalled memories were actually helpful in the conversation
    /// - Parameters:
    ///   - transcript: The conversation text
    ///   - recalledMemories: The memories that were injected as context
    /// - Returns: A dictionary mapping memory ID strings to a helpfulness score (-1.0 to 1.0)
    func evaluateRecallPerformance(
        transcript: String,
        recalledMemories: [Memory]
    ) async throws -> [String: Double] {
        guard !recalledMemories.isEmpty else {
            return [:]
        }

        return await runUtilityGeneration(
            UtilityGenerationDirective.recallPerformance(
                transcript: transcript,
                recalledMemories: recalledMemories
            ),
            logger: utilityGenerationLogger
        )
    }
}

private extension LLMUtilityClient where Self: LLMStreamClient {
    var utilityGenerationLogger: Logger {
        if let provider = self as? any UtilityGenerationLoggerProviding {
            return provider.utilityGenerationLogger
        }
        return Logger.module(named: "llm")
    }

    func runUtilityGeneration<Payload: Decodable & Sendable, Output: Sendable>(
        _ directive: UtilityGenerationDirective<Payload, Output>,
        logger: Logger
    ) async -> Output {
        do {
            let payload = try await sendStructured(
                directive.prompt,
                structuredOutput: directive.structuredOutput,
                as: directive.payloadType,
                generationParameters: nil,
                modelTier: .utility
            )
            return directive.map(payload)
        } catch {
            logger.error("Failed to \(directive.logLabel): \(ErrorKit.userFriendlyMessage(for: error))")
            return directive.defaultValue
        }
    }
}

private protocol UtilityGenerationLoggerProviding {
    var utilityGenerationLogger: Logger { get }
}

extension LLMService: UtilityGenerationLoggerProviding {
    nonisolated var utilityGenerationLogger: Logger {
        logger
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
