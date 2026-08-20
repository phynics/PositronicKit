import ErrorKit
import Foundation
import Logging
import JSONSchemaBuilder
import PKContracts
import PKUtilities

/// Strict utility-generation operations.
///
/// Failures propagate to the caller so policy stays at the boundary that owns it (for
/// example, `ThreadArchiver`'s title fallback). The compatibility surface
/// `BestEffortLLMUtilities` re-introduces the log-and-return-default behavior for
/// `LLMUtilityClient` conformance (`bestEffortTags(for:)` / `bestEffortTitle(for:)`).
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

    /// Generates a concise conversation title, throwing on failure.
    ///
    /// An empty message list is not a provider failure: it maps to the documented
    /// `"New Conversation"` default without invoking the model.
    public func generateTitle(for messages: [Message]) async throws -> String {
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

    func bestEffortTags(for text: String) async -> [String] {
        do {
            return try await LLMUtilityGenerator(streamClient: streamClient).generateTags(for: text)
        } catch {
            logger.error("Failed to generate tags: \(ErrorKit.userFriendlyMessage(for: error))")
            return []
        }
    }

    func bestEffortTitle(for messages: [Message]) async -> String {
        do {
            return try await LLMUtilityGenerator(streamClient: streamClient).generateTitle(for: messages)
        } catch {
            logger.error("Failed to generate title: \(ErrorKit.userFriendlyMessage(for: error))")
            return "New Conversation"
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

@Schemable
struct LLMTagResponse: Codable {
    let tags: [String]
}

@Schemable
struct LLMTitleResponse: Codable {
    let title: String
}
