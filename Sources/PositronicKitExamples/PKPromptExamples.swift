import Foundation
import PKPrompt
import PKShared

public enum PKPromptExamples {
    public static func makeToolingPrompt(
        tools: [String],
        history: [Message],
        userQuery: String
    ) -> some Prompt {
        let toolSummary = tools.map { "- \($0)" }.joined(separator: "\n")

        return AnyPrompt.build {
            SystemPrompt("You are helping with PositronicKit setup.")

            ContextPrompt(
                toolSummary,
                id: "available_tools",
                priority: PromptPriority.high.rawValue,
                compression: .summarize,
                cachePolicy: .semiStable
            )

            HistoryPrompt(history)
            UserPrompt(userQuery)
        }
    }
}
