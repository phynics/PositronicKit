import Foundation
import JSONSchemaBuilder
import PKPrompt
import PKShared
import PKUtilities
import PositronicKit

/// Compile-checked mirrors of the code snippets in `README.md`.
///
/// Keep these functions in sync with the README so the examples never drift out of date.
public enum READMEExamples {
    /// README "Prompt composition with PKPrompt" example.
    public static func readmePromptCompositionExample() async throws -> RenderedPrompt {
        let prompt = AnyPrompt.build {
            SystemPrompt("You are helping with project tooling.")
            TextPrompt("- build\n- test\n- lint", id: "tools")
                .compression(.summarize)
                .cachePolicy(.semiStable)
            UserPrompt("Recommend the safest next step.")
        }

        let assembled = try prompt.assemblePrompt()
        let rendered = await assembled.render()

        print(rendered.sections.map(\.id))
        return rendered
    }

    /// README "Prompt journaling across snapshots" example.
    public static func readmePromptJournalExample() async throws -> (
        initialPlan: PromptJournalPlan,
        updatedPlan: PromptJournalPlan,
        compactedPlan: PromptJournalPlan?
    ) {
        struct AvailableTool: Sendable {
            let id: String
            let summary: String
        }

        func render(tools: [AvailableTool], query: String) async throws -> RenderedPrompt {
            try await AnyPrompt.build {
                SystemPrompt("You are a helpful coding assistant.")
                ForEach(tools) { tool in
                    TextPrompt(tool.summary, id: "tool-\(tool.id)")
                        .cachePolicy(.semiStable)
                }
                UserPrompt(query)
                    .cachePolicy(.volatile)
            }.assemblePrompt().render()
        }

        var journal = PromptJournal()

        let first = try await render(tools: [
            .init(id: "build", summary: "Builds the package."),
            .init(id: "test", summary: "Runs tests."),
        ], query: "What should I run first?")

        let second = try await render(tools: [
            .init(id: "build", summary: "Builds the package."),
            .init(id: "test", summary: "Runs the full test suite."),
            .init(id: "lint", summary: "Checks formatting and style."),
        ], query: "What should I run first?")

        let initialPlan = journal.observe(first)
        print(initialPlan.baseSections.map(\.section.id))
        // ["system", "tool-build", "tool-test"]
        print(initialPlan.overlaySections.isEmpty)

        let updatedPlan = journal.observe(second)
        print(updatedPlan.baseSections.map(\.section.id))
        // ["system", "tool-build", "tool-test"]
        print(updatedPlan.overlaySections.map(\.section.id))
        // ["tool-test", "tool-lint"]

        for overlay in updatedPlan.overlaySections {
            if case let .text(text) = overlay.section.content {
                print("\(overlay.section.id): \(text)")
            }
        }

        let compactedPlan = journal.compact()
        print(compactedPlan?.baseSections.map(\.section.id) ?? [])
        // ["system", "tool-build", "tool-test", "tool-lint"]
        print(compactedPlan?.overlaySections.isEmpty ?? false)
        return (initialPlan, updatedPlan, compactedPlan)
    }

    /// README "Sidecar directives" example.
    public static func readmeSidecarDirectivesExample(
        chat: PositronicKit,
        timelineId: UUID
    ) async throws {
        let title = SidecarDirective(
            name: "title",
            instruction: "A short conversation title (3-6 words). Return null if the conversation already has a good title.",
            schema: JSONString().definition(),
            streaming: .buffered
        )

        let stream = try await chat.run(.init(
            timelineID: timelineId,
            message: "What's the deal with actors in Swift 6?",
            sidecars: [title]
        ))

        for try await event in stream {
            if let text = event.textContent {
                print(text, terminator: "")
            }
            if let result = event.sidecarResults?.first(where: { $0.name == "title" }) {
                switch result.outcome {
                case let .value(value): print("title: \(value)")
                case .declined: print("title: declined")
                case let .failed(reason): print("title failed: \(reason)")
                }
            }
        }
    }
}
