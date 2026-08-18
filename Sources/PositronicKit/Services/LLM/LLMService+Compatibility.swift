import Foundation
import Logging
import PKShared
import PKUtilities

/// Best-effort `LLMUtilityClient` compatibility surface.
///
/// These methods intentionally never throw: failures are logged and mapped to documented
/// defaults via ``BestEffortLLMUtilities``. Callers that own fallback policy (such as
/// `ThreadArchiver`) should use the strict ``LLMUtilityGenerator`` directly instead.
public extension LLMUtilityClient where Self: LLMStreamClient {
    /// Generate tags/keywords for the given text.
    ///
    /// Best-effort: on failure, logs and returns an empty array.
    func bestEffortTags(for text: String) async -> [String] {
        await BestEffortLLMUtilities(streamClient: self, logger: utilityGenerationLogger)
            .bestEffortTags(for: text)
    }

    /// Generate a concise title for a conversation.
    ///
    /// Best-effort: on failure, logs and returns `"New Conversation"`.
    func bestEffortTitle(for messages: [Message]) async -> String {
        await BestEffortLLMUtilities(streamClient: self, logger: utilityGenerationLogger)
            .bestEffortTitle(for: messages)
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
