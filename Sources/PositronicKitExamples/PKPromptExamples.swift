import Foundation
import PKPrompt
import PKShared

public enum PKPromptExamples {
    public struct ExampleTool: Identifiable, Sendable {
        public let id: String
        public let summary: String

        public init(id: String, summary: String) {
            self.id = id
            self.summary = summary
        }
    }

    public static func makeToolingPrompt(
        tools: [String],
        history: [Message],
        userQuery: String
    ) -> some Prompt {
        let toolSummary = tools.map { "- \($0)" }.joined(separator: "\n")

        return AnyPrompt.build {
            SystemPrompt("You are helping with PositronicKit setup.")

            TextPrompt(
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

    public static func makeStableToolingPrompt(
        tools: [ExampleTool],
        userQuery: String
    ) -> some Prompt {
        AnyPrompt.build {
            SystemPrompt("You are helping with PositronicKit setup.")

            ForEach(tools) { tool in
                TextPrompt(
                    tool.summary,
                    id: "tool-\(tool.id)",
                    priority: PromptPriority.high.rawValue,
                    compression: .summarize,
                    cachePolicy: .semiStable
                )
            }

            UserPrompt(userQuery)
        }
    }
}
