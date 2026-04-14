import Foundation
import Testing
@testable import PKPrompt

private struct StaticText: PrimitiveContextSection {
    let id: String
    let text: String
    let role: PromptSectionRole
    let priority: Int
    let compression: CompressionStrategy
    let cachePolicy: CachePolicy

    init(
        id: String,
        text: String,
        role: PromptSectionRole = .context,
        priority: Int = 50,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy = .volatile
    ) {
        self.id = id
        self.text = text
        self.role = role
        self.priority = priority
        self.compression = compression
        self.cachePolicy = cachePolicy
    }

    var estimatedTokens: Int {
        max(1, text.count / 4)
    }

    func renderContent() async -> String? {
        text
    }
}

private struct ToolsSection: ContextSection {
    let tools: [String]

    private var toolString: String {
        tools.map { "- \($0)" }.joined(separator: "\n")
    }

    @ContextBuilder
    var body: some ContextSection {
        StaticText(id: "tools", text: toolString, role: .system)
            .priority(.high)
            .compression(.drop)
            .cachePolicy(.semiStable)
    }
}

@Suite("Body-based context sections")
struct BodyBasedContextSectionTests {
    @Test("Composite sections flatten into effective prompt leaves")
    func compositeSectionsFlattenIntoEffectivePromptLeaves() async {
        let prompt = Prompt {
            ToolsSection(tools: ["read", "write"])
        }

        let sections = await prompt.resolveSections()

        #expect(sections.count == 1)
        #expect(sections[0].id == "tools")
        #expect(sections[0].role == .system)
        #expect(sections[0].priority == PromptPriority.high.rawValue)
        #expect(sections[0].compression == .drop)
        #expect(sections[0].cachePolicy == .semiStable)
        #expect(sections[0].path.suffix(3).elementsEqual(["ToolsSection", "semiStable", "tools"]))

        let rendered = await sections[0].render()
        #expect(rendered == "- read\n- write")
    }

    @Test("Modifiers override primitive defaults across nested groups")
    func modifiersOverridePrimitiveDefaultsAcrossNestedGroups() async {
        struct NestedSection: ContextSection {
            @ContextBuilder
            var body: some ContextSection {
                SectionGroup {
                    StaticText(id: "low", text: "first")
                    StaticText(id: "high", text: "second", priority: 5)
                }
                .priority(90)
                .cachePolicy(.stable)
            }
        }

        let prompt = Prompt {
            NestedSection()
        }

        let sections = await prompt.resolveSections()

        #expect(sections.map(\.id) == ["low", "high"])
        #expect(sections.allSatisfy { $0.priority == 90 })
        #expect(sections.allSatisfy { $0.cachePolicy == .stable })
    }
}
