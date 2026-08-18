import Foundation
import Logging
import PKShared
import PKUtilities

/// Best-effort `LLMUtilityClient` compatibility surface.
///
/// These methods intentionally never throw during the current major version: failures are
/// logged and mapped to documented defaults via ``BestEffortLLMUtilities``. Callers that own
/// fallback policy (such as `ThreadArchiver`) should use the strict ``LLMUtilityGenerator``
/// directly instead.
public extension LLMUtilityClient where Self: LLMStreamClient {
    /// Generate tags/keywords for a given text using the LLM.
    ///
    /// Best-effort: on failure, logs and returns an empty array.
    func generateTags(for text: String) async throws -> [String] {
        await BestEffortLLMUtilities(streamClient: self, logger: utilityGenerationLogger)
            .generateTags(for: text)
    }

    /// Generate a concise title for a conversation.
    ///
    /// Best-effort: on failure, logs and returns `"New Conversation"`.
    func generateTitle(for messages: [Message]) async throws -> String {
        await BestEffortLLMUtilities(streamClient: self, logger: utilityGenerationLogger)
            .generateTitle(for: messages)
    }

    /// Evaluate which recalled memories were actually helpful in the conversation.
    ///
    /// Best-effort: on failure, logs and returns an empty dictionary.
    func evaluateRecallPerformance(
        transcript: String,
        recalledMemories: [Memory]
    ) async throws -> [String: Double] {
        await BestEffortLLMUtilities(streamClient: self, logger: utilityGenerationLogger)
            .evaluateRecallPerformance(
                transcript: transcript,
                recalledMemories: recalledMemories
            )
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

private extension LLMUtilityClient where Self: LLMStreamClient {
    var utilityGenerationLogger: Logger {
        if let provider = self as? any UtilityGenerationLoggerProviding {
            return provider.utilityGenerationLogger
        }
        return Logger.module(named: "llm")
    }
}
