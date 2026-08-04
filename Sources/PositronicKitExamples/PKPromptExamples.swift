import Foundation
import PKPrompt
import PKShared
import PKUtilities

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

    /// Applies a token budget and returns its structured sections-and-report result.
    public static func applyTokenBudget(to prompt: some Prompt) async throws -> TokenBudgetResult {
        try await TokenBudget(maxTokens: 4_096).result(forPrompts: [prompt])
    }

    // MARK: - README "Choosing A Layer" examples

    //
    // These mirror the three consumption layers documented in README.md so the
    // docs stay compile-checked. Keep them in sync with the README snippets.

    /// README Layer 1: Prompt → String.
    ///
    /// The smallest surface area: author a prompt, get canonical rendered text.
    public static func renderLayer1ToString() async throws -> String? {
        let prompt = AnyPrompt.build {
            LayerExamplePrompt(tools: ["build", "test", "lint"])
            UserPrompt("Recommend the safest next step.")
        }

        return try await prompt.renderToString()
    }

    /// README Layer 2: Prompt → AssembledPrompt → RenderedPrompt.
    ///
    /// Full visibility into validated sections, rendered content, and compression outcomes.
    public static func assembleLayer2() async throws -> (AssembledPrompt, RenderedPrompt) {
        let prompt = AnyPrompt.build {
            SystemPrompt("You are helping with project tooling.")
            TextPrompt("- build\n- test\n- lint", id: "tools")
                .compression(.summarize)
                .cachePolicy(.semiStable)
            UserPrompt("Recommend the safest next step.")
        }

        let assembled = try prompt.assemblePrompt()
        let rendered = await assembled.render()
        return (assembled, rendered)
    }

    /// README Layer 3: RenderedPrompt → PromptJournal.
    ///
    /// Prompt structure survives across snapshots: stable content stays materialized,
    /// semi-stable changes become overlays, volatile content stays current-only, and accepted
    /// assistant/tool appends can trigger auto-compaction into a new baseline.
    public static func journalLayer3() async throws -> (
        initialPlan: PromptJournalPlan,
        updatedPlan: PromptJournalPlan,
        autoCompactedPlan: PromptJournalPlan,
        compactedPlan: PromptJournalPlan?
    ) {
        var journal = PromptJournal(thresholds: .init(maxAppendedTokens: 1, maxAppendedMessages: 1))

        let first = try await AnyPrompt.build {
            SystemPrompt("You are helping with project tooling.")
            TextPrompt("- build\n- test\n- lint", id: "tools")
                .cachePolicy(.semiStable)
            UserPrompt("Recommend the safest next step.")
        }.assemblePrompt().render()

        let second = try await AnyPrompt.build {
            SystemPrompt("You are helping with project tooling.")
            TextPrompt("- build\n- test\n- lint\n- format", id: "tools")
                .cachePolicy(.semiStable)
            UserPrompt("Recommend the safest next step.")
        }.assemblePrompt().render()

        let initialPlan = journal.observe(first)
        let updatedPlan = journal.observe(second)
        journal.recordAppend(messages: [
            Message(content: "Use build, then verify with tests.", role: .assistant),
            Message(content: "Tool output: build succeeded.", role: .tool),
        ])
        let autoCompactedPlan = journal.observe(second)
        let compactedPlan = journal.compact()
        return (initialPlan, updatedPlan, autoCompactedPlan, compactedPlan)
    }
}

/// Supporting type for README Layer 1: a custom `Prompt` authored via `var body`.
public struct LayerExamplePrompt: Prompt {
    public let tools: [String]

    public init(tools: [String]) {
        self.tools = tools
    }

    public var body: some Prompt {
        SystemPrompt("You are helping with project tooling.")

        TextPrompt(tools.map { "- \($0)" }.joined(separator: "\n"), id: "tools")
            .compression(.summarize)
            .cachePolicy(.semiStable)
    }
}
