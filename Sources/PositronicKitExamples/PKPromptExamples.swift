import Foundation
import PKPrompt
import PKShared

public enum PKPromptExamples {
    public static func makeToolingPrompt(
        tools: [String],
        history: [Message],
        userQuery: String
    ) -> Prompt<some PromptComposite> {
        let toolSummary = tools.map { "- \($0)" }.joined(separator: "\n")

        return Prompt {
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
