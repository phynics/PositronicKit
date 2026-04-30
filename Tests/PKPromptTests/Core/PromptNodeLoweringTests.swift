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
        if case let .fork(children) = node?.nodeType {
            #expect(children.count == 2)
            #expect(children.allSatisfy { if case .leaf = $0.nodeType { return true } else { return false } } == true)
        } else {
            Issue.record("Expected fork node")
        }
    }

    @Test("Prompt modifiers lower into passthrough nodes carrying inherited traits")
    func modifiersLowerIntoPromptNodes() {
        let node = LoweringStaticText(id: "first", text: "one")
            .priority(.high)
            .compression(.summarize)
            .cachePolicy(.stable)

        let lowered = node.makeNode()

        #expect(lowered != nil)
        #expect(lowered?.cachePolicy == .stable)
        if case let .fork(children1) = lowered?.nodeType {
            #expect(children1.count == 1)
            #expect(children1[0].compression == .summarize)
            if case let .fork(children2) = children1[0].nodeType {
                #expect(children2[0].priority == PromptPriority.high.rawValue)
            } else {
                Issue.record("Expected nested fork node")
            }
        } else {
            Issue.record("Expected fork node")
        }
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

    @Test("Identifiable prompts include their stable identity in path boundaries")
    func identifiablePromptsPreserveIdentityInPaths() {
        struct IdentifiedPrompt: Prompt, Identifiable {
            let id: String

            @PromptBuilder
            var body: some Prompt {
                LoweringStaticText(id: "leaf", text: "value")
            }
        }

        let prompt = IdentifiedPrompt(id: "alpha")
        let sections = try! prompt.assemblePrompt().sections

        #expect(sections.count == 1)
        #expect(sections[0].path.contains("IdentifiedPrompt \(AnyHashable(prompt.id).hashValue)"))
        #expect(sections[0].path.last == "leaf")
    }
}
