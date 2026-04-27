import Foundation
import Testing
@testable import PKPrompt

private struct LoweringStaticText: PromptPrimitive {
    let id: String
    let text: String
    let priority = PromptPriority.medium.rawValue

    var estimatedTokens: Int { max(1, text.count / 4) }

    func renderContent() async -> String? {
        text
    }
}

@Suite("PromptNode lowering")
struct PromptNodeLoweringTests {
    @Test("PromptBuilder lowers composition into concrete prompt nodes")
    func builderLowersIntoPromptNodeTree() {
        let node = AnyPrompt {
            LoweringStaticText(id: "first", text: "one")
            LoweringStaticText(id: "second", text: "two")
        }.makePromptNode()

        #expect(node != nil)
        #expect(node?.children.count == 2)
        #expect(node?.isLeaf == false)
        #expect(node?.children.allSatisfy { $0.isLeaf } == true)
    }

    @Test("Prompt modifiers lower into passthrough nodes carrying inherited traits")
    func modifiersLowerIntoPromptNodes() {
        let node = LoweringStaticText(id: "first", text: "one")
            .priority(.high)
            .compression(.summarize)
            .cachePolicy(.stable)

        let lowered = PromptAssembly.makeNode(from: node)

        #expect(lowered != nil)
        #expect(lowered?.cachePolicy == .stable)
        #expect(lowered?.children.count == 1)
        #expect(lowered?.children[0].compression == .summarize)
        #expect(lowered?.children[0].children[0].priority == PromptPriority.high.rawValue)
    }

    @Test("Body-based prompts preserve type path boundaries after builder lowering")
    func bodyBasedPromptsPreserveTypePathBoundaries() {
        struct NestedPrompt: Prompt {
            @PromptBuilder
            var body: some Prompt {
                LoweringStaticText(id: "leaf", text: "value")
            }
        }

        let sections = try! NestedPrompt().assemblePrompt().sections
        #expect(sections.count == 1)
        #expect(sections[0].path.contains("NestedPrompt"))
        #expect(sections[0].path.last == "leaf")
    }
}
