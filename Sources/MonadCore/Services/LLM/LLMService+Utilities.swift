import Foundation
import Logging
import MonadShared
import OpenAI

public extension LLMServiceProtocol {
    /// Generate tags/keywords for a given text using the LLM
    func generateTags(for text: String) async throws -> [String] {
        let prompt = """
        Extract 3-5 relevant keywords or tags from the following text.
        Return ONLY a JSON object with a key "tags" containing an array of strings.

        Text:
        \(text)
        """

        do {
            let response = try await self.sendMessage(
                prompt,
                responseFormat: .jsonObject,
                generationParameters: nil,
                useUtilityModel: true
            )

            // Clean up response (some models might still include markdown)
            var cleanJson = response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if cleanJson.hasPrefix("```json") {
                cleanJson = cleanJson.replacingOccurrences(of: "```json", with: "")
            }
            if cleanJson.hasPrefix("```") {
                cleanJson = cleanJson.replacingOccurrences(of: "```", with: "")
            }
            cleanJson = cleanJson.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            guard let data = cleanJson.data(using: String.Encoding.utf8),
                  let tagResponse = try? JSONDecoder().decode(LLMTagResponse.self, from: data)
            else {
                Logger.module(named: "llm").warning("Failed to parse tags from LLM response: \(response)")
                return []
            }

            return tagResponse.tags.map { $0.lowercased() }
        } catch {
            Logger.module(named: "llm").error("Failed to generate tags: \(error.localizedDescription)")
            return []
        }
    }

    /// Generate a concise title for a conversation
    func generateTitle(for messages: [Message]) async throws -> String {
        guard !messages.isEmpty else {
            return "New Conversation"
        }

        let transcript = messages.map { "[\($0.role.rawValue.uppercased())] \($0.content)" }.joined(
            separator: "\n\n"
        )

        let prompt = """
        Based on the following conversation transcript, generate a concise, descriptive title (maximum 6 words).
        Return ONLY the title text, no quotes or additional formatting.

        TRANSCRIPT:
        \(transcript)
        """

        do {
            let response = try await self.sendMessage(
                prompt,
                responseFormat: nil,
                generationParameters: nil,
                useUtilityModel: true
            )
            let title = response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")

            return title.isEmpty ? "New Conversation" : title
        } catch {
            Logger.module(named: "llm").error("Failed to generate title: \(error.localizedDescription)")
            return "New Conversation"
        }
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

        let memoriesText = recalledMemories.map {
            "- ID: \($0.id.uuidString)\n  Title: \($0.title)\n  Content: \($0.content)"
        }.joined(separator: "\n\n")

        let prompt = """
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
        """

        do {
            let response = try await self.sendMessage(
                prompt,
                responseFormat: .jsonObject,
                generationParameters: nil,
                useUtilityModel: true
            )

            // Clean up response
            var cleanJson = response.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if cleanJson.hasPrefix("```json") {
                cleanJson = cleanJson.replacingOccurrences(of: "```json", with: "")
            }
            if cleanJson.hasPrefix("```") {
                cleanJson = cleanJson.replacingOccurrences(of: "```", with: "")
            }
            cleanJson = cleanJson.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            guard let data = cleanJson.data(using: String.Encoding.utf8),
                  let scores = try? JSONDecoder().decode([String: Double].self, from: data)
            else {
                Logger.module(named: "llm").warning(
                    "Failed to parse recall evaluation from LLM response: \(response)"
                )
                return [:]
            }

            return scores
        } catch {
            Logger.module(named: "llm").error("Failed to evaluate recall: \(error.localizedDescription)")
            return [:]
        }
    }
}

private struct LLMTagResponse: Codable {
    let tags: [String]
}
