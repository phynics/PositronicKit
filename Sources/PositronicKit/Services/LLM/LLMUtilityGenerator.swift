import Foundation
import JSONSchemaBuilder
import PKContracts
import PKUtilities

/// Strict utility-generation operations.
///
/// Failures propagate to the caller so policy stays at the boundary that owns it (for
/// example, a caller's title fallback).
public struct LLMUtilityGenerator {
    private let streamClient: any LLMStreamClient

    public init(streamClient: any LLMStreamClient) {
        self.streamClient = streamClient
    }

    /// Generates tags/keywords for the given text, throwing on failure.
    public func generateTags(for text: String) async throws -> [String] {
        let directive = UtilityGenerationDirective.tags(text: text)
        let payload = try await send(directive)
        return directive.map(payload)
    }

    /// Generates a concise thread title, throwing on failure.
    ///
    /// An empty message list is not a provider failure: it maps to the documented
    /// `"New Thread"` default without invoking the model.
    public func generateTitle(for messages: [Message]) async throws -> String {
        guard !messages.isEmpty else {
            return "New Thread"
        }
        let transcript = messages.map { "[\($0.role.rawValue.uppercased())] \($0.content)" }.joined(
            separator: "\n\n"
        )
        let directive = UtilityGenerationDirective.title(transcript: transcript)
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

private struct UtilityGenerationDirective<Payload: Decodable & Sendable, Output: Sendable> {
    let prompt: String
    let structuredOutput: StructuredOutputRequest
    let payloadType: Payload.Type
    let map: @Sendable (Payload) -> Output
}

private extension UtilityGenerationDirective where Payload == LLMTagResponse, Output == [String] {
    static func tags(text: String) -> Self {
        Self(
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
            map: { $0.tags.map { $0.lowercased() } }
        )
    }
}

private extension UtilityGenerationDirective where Payload == LLMTitleResponse, Output == String {
    static func title(transcript: String) -> Self {
        Self(
            prompt: """
            Based on the following thread transcript, generate a concise, descriptive title (maximum 6 words).
            Return ONLY a JSON object with a key "title" containing the title text, with no surrounding quotes or additional formatting.

            TRANSCRIPT:
            \(transcript)
            """,
            structuredOutput: .jsonSchema(StructuredOutputSchema(
                name: "llm_title",
                description: "A concise thread title.",
                schema: LLMTitleResponse.schema.definition()
            )),
            payloadType: LLMTitleResponse.self,
            map: { payload in
                let title = payload.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")
                return title.isEmpty ? "New Thread" : title
            }
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
