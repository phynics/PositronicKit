import Foundation
import Logging
import PKPrompt
import PKContracts
import PKUtilities
@testable import PositronicKit
import Testing

/// Verifies `PromptSnapshotBuilder`'s incremental-string path (PKR-10) produces a
/// `RenderedPrompt.string` identical to a full from-scratch re-assembly over N appended
/// message batches. The incremental path appends each batch's text to the already-rendered
/// accumulated string instead of re-joining every prior section each turn.
@Suite(.tags(.unit))
struct PromptSnapshotBuilderTests {
    private let builder = PromptSnapshotBuilder(logger: Logger(label: "test.snapshot"))

    private func makeTextSection(_ id: String, _ text: String) -> RenderedPrompt.Section {
        RenderedPrompt.Section(
            id: id,
            role: .system,
            priority: 0,
            estimatedTokens: 1,
            compression: .keep,
            type: .text,
            cachePolicy: .volatile,
            path: [id],
            parentID: nil,
            compressionOutcome: nil,
            content: .text(text)
        )
    }

    private func makeBase() -> RenderedPrompt {
        let sections = [makeTextSection("s1", "Hello"), makeTextSection("s2", "World")]
        return RenderedPrompt(
            sections: sections,
            string: "Hello\n\n---\n\nWorld",
            sectionsByID: ["s1": "Hello", "s2": "World"]
        )
    }

    private func batch(_ contents: [String]) -> [LLMMessage] {
        contents.enumerated().map { index, content in
            LLMMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: content)
        }
    }

    @Test("Incremental synthesis over N batches matches full from-scratch re-assembly")
    func incrementalMatchesFromScratch() async throws {
        let base = makeBase()
        let batches = [batch(["a1", "a2"]), batch(["b1"]), batch(["c1", "c2", "c3"])]

        // Incremental: chain synthesizeFollowUpPrompt, each call using the prior result.
        var current = base
        for (index, messages) in batches.enumerated() {
            current = builder.synthesizeFollowUpPrompt(
                from: current,
                appendedMessages: messages,
                nextTurnIndex: index + 1
            )
        }

        // From-scratch reference: the section text contents (base sections + each batch's
        // appended content) joined with the canonical "\n\n---\n\n" separator, skipping empty.
        var allParts: [String] = ["Hello", "World"]
        var expectedSectionsByID: [String: String] = ["s1": "Hello", "s2": "World"]
        for (index, messages) in batches.enumerated() {
            let appendedContent = messages.map(\.content).joined(separator: "\n")
            allParts.append(appendedContent)
            expectedSectionsByID["runtime-follow-up-\(index + 1)"] = appendedContent
        }
        let expectedString = allParts.joined(separator: "\n\n---\n\n")

        #expect(current.string == expectedString)
        #expect(current.sectionsByID == expectedSectionsByID)
        #expect(current.sections.count == base.sections.count + batches.count)
    }

    @Test("Empty appended messages returns the base prompt unchanged")
    func emptyAppendedMessagesReturnsBase() async throws {
        let base = makeBase()
        let result = builder.synthesizeFollowUpPrompt(
            from: base,
            appendedMessages: [],
            nextTurnIndex: 1
        )

        #expect(result.string == base.string)
        #expect(result.sections.count == base.sections.count)
        #expect(result.sectionsByID == base.sectionsByID)
    }

    @Test("buildFollowUpSnapshot synthesizes the next prompt without journal state")
    func buildFollowUpSnapshotSynthesizesPrompt() throws {
        let base = makeBase()
        let context = TurnContext(
            timelineID: UUID(),
            agentId: nil,
            modelName: "test-model",
            maxModelRounds: 5,
            systemInstructions: nil,
            availableTools: [],
            remoteDepth: 0,
            promptHistory: TimelinePromptHistory(),
            renderedPrompt: base,
            currentMessages: [],
            modelRoundIndex: 1,
            outputs: TurnOutputs()
        )

        let snapshot = builder.buildFollowUpSnapshot(
            from: context,
            appendedMessages: batch(["follow-up"]),
            nextTurnIndex: 1
        )

        let rendered = try #require(snapshot)
        #expect(rendered.sections.count == base.sections.count + 1)
        #expect(rendered.string.contains("follow-up"))
    }

    @Test("Incremental string over a base with an empty section still aligns")
    func incrementalWithEmptyBaseSection() async throws {
        // A base whose first section is empty: AssembledPrompt.render() skips empty content,
        // so the rendered string starts from the non-empty section. The incremental path
        // must match that skip behavior.
        let sections = [makeTextSection("empty", ""), makeTextSection("s2", "World")]
        let base = RenderedPrompt(
            sections: sections,
            string: "World",
            sectionsByID: ["empty": "", "s2": "World"]
        )

        let current = builder.synthesizeFollowUpPrompt(
            from: base,
            appendedMessages: batch(["next"]),
            nextTurnIndex: 1
        )

        // base.string ("World") + separator + "next"
        #expect(current.string == "World\n\n---\n\nnext")
        #expect(current.sectionsByID["runtime-follow-up-1"] == "next")
    }
}
