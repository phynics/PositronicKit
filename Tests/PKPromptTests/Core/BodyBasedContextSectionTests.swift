import Foundation
import Testing
@testable import PKPrompt
@testable import PKShared

private struct StaticText: PromptLeaf {
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

private struct ToolsSection: PromptComposite {
    let tools: [String]

    private var toolString: String {
        tools.map { "- \($0)" }.joined(separator: "\n")
    }

    @PromptBuilder
    var body: some PromptComposite {
        StaticText(id: "tools", text: toolString, role: .system)
            .priority(.high)
            .compression(.drop)
            .cachePolicy(.semiStable)
    }
}

@Suite("Body-based context sections")
struct BodyBasedPromptCompositeTests {
    @Test("Composite sections flatten into effective prompt leaves")
    func compositeSectionsFlattenIntoEffectivePromptLeaves() async {
        let sections = ToolsSection(tools: ["read", "write"]).assembledPrompt().resolvedSections

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

    @Test("Modifiers override prompt leaf defaults across nested groups")
    func modifiersOverridePrimitiveDefaultsAcrossNestedGroups() async {
        struct NestedSection: PromptComposite {
            @PromptBuilder
            var body: some PromptComposite {
                PromptAny {
                    StaticText(id: "low", text: "first")
                    StaticText(id: "high", text: "second", priority: 5)
                }
                .priority(90)
                .cachePolicy(.stable)
            }
        }

        let sections = NestedSection().assembledPrompt().resolvedSections

        #expect(sections.map(\.id) == ["low", "high"])
        #expect(sections.allSatisfy { $0.priority == 90 })
        #expect(sections.allSatisfy { $0.cachePolicy == .stable })
    }

    @Test("Convenience prompt leaves provide ergonomic authoring defaults")
    func conveniencePromptLeavesProvideErgonomicDefaults() async {
        let prompt = Prompt {
            SystemPrompt("You are a careful assistant.")
            ContextPrompt("Project uses Swift 6.", id: "project")
                .priority(.high)
                .compression(.summarize)
            UserPrompt("Add a toolbar action.")
        }

        let sections = prompt.assembledPrompt().resolvedSections

        #expect(sections.map(\.id) == ["system", "project", "user_query"])
        #expect(sections[0].role == .system)
        #expect(sections[0].cachePolicy == .stable)
        #expect(sections[1].priority == PromptPriority.high.rawValue)
        #expect(sections[1].compression == .summarize)
        #expect(sections[2].role == .userQuery)
    }

    @Test("HistoryPrompt resolves to chat history leaves")
    func historyPromptResolvesToChatHistoryLeaves() async {
        let sections = HistoryPrompt([
            Message(content: "First", role: .user),
            Message(content: "Second", role: .assistant),
        ]).assembledPrompt().resolvedSections

        #expect(sections.count == 1)
        #expect(sections[0].id == "chat_history")
        #expect(sections[0].role == PromptSectionRole.chatHistory)
        if case let .messages(messages)? = await sections[0].renderedContent() {
            #expect(messages.map(\.role) == [.user, .assistant])
            #expect(messages.map(\.content) == ["First", "Second"])
        } else {
            #expect(Bool(false), "History section should render message content")
        }
        #expect(await sections[0].render() == nil)
    }
}
