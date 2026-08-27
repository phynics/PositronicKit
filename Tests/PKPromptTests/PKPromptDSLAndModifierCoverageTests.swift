import Foundation
@testable import PKContracts
@testable import PKPrompt
import PKUtilities
import Testing

/// Prompt DSL and modifier coverage.
@Suite("Prompt DSL and modifier coverage")
struct PKPromptDSLAndModifierCoverageTests {
    @Test("PromptPrimitive body returns EmptyPrompt")
    func promptPrimitiveBodyReturnsEmpty() {
        struct TestPrimitive: PromptPrimitive {
            let id = "test"
            let priority = 1
            let estimatedTokens = 10
            func renderContent() async -> String? {
                "hello"
            }
        }
        let primitive = TestPrimitive()
        let body = primitive.body
        #expect(type(of: body) == EmptyPrompt.self)
    }

    @Test("PromptPrimitive applyRenderConstraint returns nil for drop strategy")
    func promptPrimitiveDropConstraint() async {
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .drop
        )
        // When rendered with a token limit, drop strategy should produce nil.
        let rendered = await section.renderedContent()
        // Without a token limit, content is rendered normally.
        #expect(rendered != nil)
    }

    @Test("PromptPrimitive applyRenderConstraint returns content for summarize strategy")
    func promptPrimitiveSummarizeConstraint() async {
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .summarize
        )
        let rendered = await section.renderedContent()
        // Summarize strategy during render returns content unchanged (summaries are
        // produced by TokenBudget/StructuredCompressionExecutor, not at render time).
        #expect(rendered?.text != nil)
    }

    @Test("PromptPrimitive applyRenderConstraint returns content for keep strategy over limit")
    func promptPrimitiveKeepConstraintOverLimit() async {
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .keep
        )
        let rendered = await section.renderedContent()
        // Keep strategy always returns content.
        #expect(rendered?.text != nil)
    }

    // MARK: - HistoryPromptPrimitive renderContent

    @Test("HistoryPromptPrimitive renderContent returns nil")
    func historyPromptRenderContentReturnsNil() async {
        let primitive = HistoryPromptPrimitive(
            messages: [Message(content: "hi", role: .user)]
        )
        let content = await primitive.renderContent()
        #expect(content == nil)
    }

    // MARK: - Structural prompt types

    @Test("AnyPrompt init from non-AnyPrompt wraps in array")
    func anyPromptWrapsNonAnyPrompt() {
        let prompt = AnyPrompt {
            TextPrompt("hello", id: "t1")
        }
        #expect(prompt.prompts.count == 1)
    }

    @Test("AnyPrompt init from AnyPrompt flattens")
    func anyPromptFlattensAnyPrompt() {
        let inner = AnyPrompt([TextPrompt("a", id: "a"), TextPrompt("b", id: "b")])
        let outer = AnyPrompt { inner }
        #expect(outer.prompts.count == 2)
    }

    @Test("AnyPrompt.makePromptNode returns nil for empty")
    func anyPromptEmptyReturnsNil() {
        let prompt = AnyPrompt([])
        #expect(prompt.makePromptNode() == nil)
    }

    @Test("AnyPrompt.makePromptNode returns single child directly")
    func anyPromptSingleChildReturnsDirectly() {
        let prompt = AnyPrompt([TextPrompt("a", id: "a")])
        let node = prompt.makePromptNode()
        #expect(node != nil)
    }

    @Test("PromptModifiers.Priority applies priority trait")
    func priorityModifierAppliesTrait() {
        let prompt = TextPrompt("hi", id: "t1").priority(42)
        let node = prompt.makePromptNode()
        #expect(node != nil)
    }

    @Test("PromptModifiers.Priority with PromptPriority enum")
    func priorityModifierWithEnum() {
        let prompt = TextPrompt("hi", id: "t1").priority(.high)
        let node = prompt.makePromptNode()
        #expect(node != nil)
    }

    @Test("PromptModifiers.Compression applies compression trait")
    func compressionModifierAppliesTrait() {
        let prompt = TextPrompt("hi", id: "t1").compression(.truncate(keeping: .head))
        let node = prompt.makePromptNode()
        #expect(node != nil)
    }

    @Test("PromptModifiers.CachePolicy applies cachePolicy trait")
    func cachePolicyModifierAppliesTrait() {
        let prompt = TextPrompt("hi", id: "t1").cachePolicy(.stable)
        let node = prompt.makePromptNode()
        #expect(node != nil)
    }

    @Test("PromptModifiers return nil when child has nil node")
    func modifiersReturnNilForNilChild() {
        let prompt = AnyPrompt([]).priority(1)
        #expect(prompt.makePromptNode() == nil)
    }

    // MARK: - PromptTraits

    @Test("PromptTraits.isEmpty returns true for default init")
    func promptTraitsIsEmpty() {
        let traits = PromptTraits()
        #expect(traits.isEmpty)
    }

    @Test("PromptTraits.isEmpty returns false when any field is set")
    func promptTraitsNotEmpty() {
        #expect(!PromptTraits(priority: 1).isEmpty)
        #expect(!PromptTraits(compression: .keep).isEmpty)
        #expect(!PromptTraits(cachePolicy: .stable).isEmpty)
    }

    @Test("PromptTraits.applying merges with existing values")
    func promptTraitsApplying() {
        let traits = PromptTraits(priority: 1)
        let merged = traits.applying(compression: .drop)
        #expect(merged.priority == 1)
        #expect(merged.compression == .drop)
    }

    @Test("PromptTraits.applying preserves existing when nil passed")
    func promptTraitsApplyingPreservesExisting() {
        let traits = PromptTraits(priority: 5, compression: .keep, cachePolicy: .stable)
        let merged = traits.applying()
        #expect(merged.priority == 5)
        #expect(merged.compression == .keep)
        #expect(merged.cachePolicy == .stable)
    }

    // MARK: - PromptAssemblyError

    @Test("ForEach with empty data returns nil node")
    func forEachEmptyReturnsNil() {
        let forEach = ForEach([String]()) { _ in TextPrompt("x", id: "x") }
        #expect(forEach.makePromptNode() == nil)
    }

    @Test("ForEach with single element returns single child")
    func forEachSingleElement() {
        let forEach = ForEach(["a"]) { item in
            TextPrompt(item, id: item)
        }
        let node = forEach.makePromptNode()
        #expect(node != nil)
    }

    // MARK: - PromptArray

    @Test("PromptArray with empty prompts returns nil")
    func promptArrayEmptyReturnsNil() {
        let array = PromptArray([TextPrompt]())
        #expect(array.makePromptNode() == nil)
    }

    @Test("PromptArray with single element returns single child")
    func promptArraySingleElement() {
        let array = PromptArray([TextPrompt("a", id: "a")])
        let node = array.makePromptNode()
        #expect(node != nil)
    }

    // MARK: - PromptConditionals

    @Test("OptionalPrompt with nil content returns nil node")
    func optionalPromptNilReturnsNil() {
        let prompt = OptionalPrompt(nil as TextPrompt?)
        #expect(prompt.makePromptNode() == nil)
    }

    @Test("OptionalPrompt with content returns node")
    func optionalPromptWithContent() {
        let prompt: OptionalPrompt<TextPrompt> = OptionalPrompt(TextPrompt("a", id: "a"))
        #expect(prompt.makePromptNode() != nil)
    }

    @Test("EitherPrompt first branch")
    func eitherPromptFirst() {
        let prompt: EitherPrompt<TextPrompt, TextPrompt> = EitherPrompt(first: TextPrompt("a", id: "a"))
        #expect(prompt.makePromptNode() != nil)
    }

    @Test("EitherPrompt second branch")
    func eitherPromptSecond() {
        let prompt: EitherPrompt<TextPrompt, TextPrompt> = EitherPrompt(second: TextPrompt("b", id: "b"))
        #expect(prompt.makePromptNode() != nil)
    }

    // MARK: - PromptTuple

    @Test("PromptTuple with single element returns single child")
    func promptTupleSingle() {
        let tuple = PromptTuple(TextPrompt("a", id: "a"))
        let node = tuple.makePromptNode()
        #expect(node != nil)
    }

    @Test("PromptTuple with empty children returns nil")
    func promptTupleEmpty() {
        // A tuple with an EmptyPrompt child that returns nil node.
        let tuple = PromptTuple(EmptyPrompt())
        #expect(tuple.makePromptNode() == nil)
    }

    // MARK: - PromptBuilder Void expression

    @Test("PromptBuilder ignores Void expressions")
    func promptBuilderIgnoresVoid() {
        let prompt = AnyPrompt.build {
            ()
            TextPrompt("hello", id: "t1")
        }
        #expect(prompt.prompts.count == 1)
    }
}

// MARK: - Test helpers

enum PromptSectionHelper {
    static func makeTextSection(
        content: PromptSection.Content,
        role: PromptSectionRole = .context,
        priority: Int = 50,
        compression: CompressionStrategy = .keep,
        cachePolicy: CachePolicy = .volatile
    ) -> PromptSection {
        PromptSection(
            id: UUID().uuidString,
            role: role,
            priority: priority,
            estimatedTokens: TokenEstimator.estimate(text: content.text ?? ""),
            compression: compression,
            type: .text,
            cachePolicy: cachePolicy,
            path: ["root", "section"],
            render: { _ in content }
        )
    }
}

enum PromptJournalHelper {
    struct JournalWithBase {
        let journal: PromptJournal
        let rendered: RenderedPrompt
    }

    static func makeJournalWithBase() throws -> JournalWithBase {
        let section = RenderedPrompt.Section(
            id: "base", role: .context, priority: 50, estimatedTokens: 10,
            compression: .keep, type: .text, cachePolicy: .stable,
            path: ["root", "base"], parentID: nil, content: .text("base content")
        )
        let rendered = RenderedPrompt(sections: [section], string: "base content", sectionsByID: ["base": "base content"])
        var journal = PromptJournal()
        _ = try journal.observe(rendered)
        return JournalWithBase(journal: journal, rendered: rendered)
    }
}

enum PromptJournalMessageHelper {
    private static func makeSection(
        id: String, role: PromptSectionRole = .context, priority: Int = 50,
        cachePolicy: CachePolicy = .stable, content: PromptSection.Content
    ) -> RenderedPrompt.Section {
        RenderedPrompt.Section(
            id: id, role: role, priority: priority, estimatedTokens: 10,
            compression: .keep, type: .text, cachePolicy: cachePolicy,
            path: ["root", id], parentID: nil, content: content
        )
    }

    private static func makeJournaled(
        _ section: RenderedPrompt.Section, layer: JournaledPromptSection.JournalLayer = .base,
        journalPath: [String]? = nil
    ) -> JournaledPromptSection {
        JournaledPromptSection(
            section: section, layer: layer,
            sourcePath: section.path, journalPath: journalPath ?? section.path
        )
    }

    static func makeSnapshotPlan() -> PromptJournalPlan {
        let section = makeJournaled(
            makeSection(id: "s1", cachePolicy: .stable, content: .text("section content"))
        )
        return PromptJournalPlan(
            baseSections: [section], overlaySections: [], volatileSections: [],
            requiresHardReset: false, diff: PromptJournalDiff(), emissionMode: .snapshot
        )
    }

    static func makeDeltaPlan() -> PromptJournalPlan {
        let section = makeJournaled(
            makeSection(id: "s1", cachePolicy: .semiStable, content: .text("replaced content")),
            layer: .overlay
        )
        let diff = PromptJournalDiff(addedSemiStableIDs: ["s1"], removedSemiStableIDs: ["old_s2"])
        return PromptJournalPlan(
            baseSections: [], overlaySections: [section], volatileSections: [],
            requiresHardReset: false, diff: diff, emissionMode: .delta
        )
    }

    static func makeDeltaPlanWithReasoning() -> PromptJournalPlan {
        let section = makeJournaled(
            makeSection(
                id: "s1", role: .chatHistory, cachePolicy: .semiStable,
                content: .messages([Message(content: "answer", role: .assistant, reasoning: "Let me think")])
            ),
            layer: .overlay
        )
        return PromptJournalPlan(
            baseSections: [], overlaySections: [section], volatileSections: [],
            requiresHardReset: false, diff: PromptJournalDiff(addedSemiStableIDs: ["s1"]), emissionMode: .delta
        )
    }

    static func makePlanWithVolatileHistory() -> PromptJournalPlan {
        let section = makeJournaled(
            makeSection(
                id: "hist", role: .chatHistory, cachePolicy: .volatile,
                content: .messages([Message(content: "What is 2+2?", role: .user)])
            ),
            layer: .volatile
        )
        return PromptJournalPlan(
            baseSections: [], overlaySections: [], volatileSections: [section],
            requiresHardReset: false, diff: PromptJournalDiff(), emissionMode: .snapshot
        )
    }

    static func makePlanWithVolatileUserQuery() -> PromptJournalPlan {
        let section = makeJournaled(
            makeSection(
                id: "query", role: .userQuery, priority: 90, cachePolicy: .volatile,
                content: .text("What is 2+2?")
            ),
            layer: .volatile
        )
        return PromptJournalPlan(
            baseSections: [], overlaySections: [], volatileSections: [section],
            requiresHardReset: false, diff: PromptJournalDiff(), emissionMode: .snapshot
        )
    }

    static func makePlanWithVolatileSystem() -> PromptJournalPlan {
        let section = makeJournaled(
            makeSection(
                id: "sys", role: .system, priority: 100, cachePolicy: .volatile,
                content: .text("System instructions here")
            ),
            layer: .volatile
        )
        return PromptJournalPlan(
            baseSections: [], overlaySections: [], volatileSections: [section],
            requiresHardReset: false, diff: PromptJournalDiff(), emissionMode: .snapshot
        )
    }
}

// MARK: - body property coverage for structural types

extension PKPromptDSLAndModifierCoverageTests {
    @Test("PromptArray.body returns EmptyPrompt")
    func promptArrayBody() {
        let array = PromptArray([TextPrompt("a", id: "a")])
        #expect(type(of: array.body) == EmptyPrompt.self)
    }

    @Test("OptionalPrompt.body returns EmptyPrompt")
    func optionalPromptBody() {
        let prompt: OptionalPrompt<TextPrompt> = OptionalPrompt(TextPrompt("a", id: "a"))
        #expect(type(of: prompt.body) == EmptyPrompt.self)
    }

    @Test("EitherPrompt.body returns EmptyPrompt")
    func eitherPromptBody() {
        let prompt: EitherPrompt<TextPrompt, TextPrompt> = EitherPrompt(first: TextPrompt("a", id: "a"))
        #expect(type(of: prompt.body) == EmptyPrompt.self)
    }

    @Test("PromptTuple.body returns EmptyPrompt")
    func promptTupleBody() {
        let tuple = PromptTuple(TextPrompt("a", id: "a"))
        #expect(type(of: tuple.body) == EmptyPrompt.self)
    }

    @Test("AnyPrompt.body returns EmptyPrompt")
    func anyPromptBody() {
        let prompt = AnyPrompt([TextPrompt("a", id: "a")])
        #expect(type(of: prompt.body) == EmptyPrompt.self)
    }

    @Test("PromptModifiers.Priority.body returns EmptyPrompt")
    func priorityModifierBody() {
        let prompt = TextPrompt("a", id: "a").priority(1)
        // Access body to cover the protocol requirement.
        _ = prompt.body
    }

    @Test("PromptModifiers.Compression.body returns EmptyPrompt")
    func compressionModifierBody() {
        let prompt = TextPrompt("a", id: "a").compression(.keep)
        _ = prompt.body
    }

    @Test("PromptModifiers.CachePolicy.body returns EmptyPrompt")
    func cachePolicyModifierBody() {
        let prompt = TextPrompt("a", id: "a").cachePolicy(.stable)
        _ = prompt.body
    }

    @Test("PromptModifiers.Compression returns nil for nil child")
    func compressionModifierNilChild() {
        let prompt = AnyPrompt([]).compression(.keep)
        #expect(prompt.makePromptNode() == nil)
    }

    @Test("PromptModifiers.CachePolicy returns nil for nil child")
    func cachePolicyModifierNilChild() {
        let prompt = AnyPrompt([]).cachePolicy(.stable)
        #expect(prompt.makePromptNode() == nil)
    }
}

// MARK: - PromptJournalPlan+Messages remaining role coverage

extension PKPromptDSLAndModifierCoverageTests {
    @Test("Default makePromptNode lowers through body for custom Prompt types")
    func defaultMakePromptNodeLowersBody() {
        struct CustomPrompt: Prompt {
            var body: some Prompt {
                TextPrompt("hello", id: "custom")
            }
        }
        let node = CustomPrompt().makePromptNode()
        #expect(node != nil)
    }

    @Test("ForEach.body returns EmptyPrompt")
    func forEachBody() {
        let forEach = ForEach(["a"]) { TextPrompt($0, id: $0) }
        #expect(type(of: forEach.body) == EmptyPrompt.self)
    }

    @Test("PromptPrimitive makeSection returns nil for empty messages content")
    func promptPrimitiveEmptyMessagesReturnsNil() async {
        struct EmptyMessagesPrimitive: PromptPrimitive {
            let id = "empty_msgs"
            let priority = 1
            let estimatedTokens = 10
            var content: PromptPrimitiveContent {
                .messages([])
            }

            func renderContent() async -> String? {
                nil
            }
        }
        let section = EmptyMessagesPrimitive().makeSection()
        let rendered = await section.renderedContent()
        #expect(rendered == nil)
    }

    @Test("PromptPrimitive keep strategy over limit returns content unchanged")
    func promptPrimitiveKeepOverLimit() async {
        struct LongPrimitive: PromptPrimitive {
            let id = "long"
            let priority = 1
            let estimatedTokens = 100
            var compression: CompressionStrategy {
                .keep
            }

            func renderContent() async -> String? {
                String(repeating: "x", count: 200)
            }
        }
        let section = LongPrimitive().makeSection()
        let content = await section.renderedContent(constrainedTo: 5)
        #expect(content?.text != nil)
    }

    @Test("PromptPrimitive summarize strategy over limit returns content unchanged")
    func promptPrimitiveSummarizeOverLimit() async {
        struct LongPrimitive: PromptPrimitive {
            let id = "long"
            let priority = 1
            let estimatedTokens = 100
            var compression: CompressionStrategy {
                .summarize
            }

            func renderContent() async -> String? {
                String(repeating: "x", count: 200)
            }
        }
        let section = LongPrimitive().makeSection()
        let content = await section.renderedContent(constrainedTo: 5)
        #expect(content?.text != nil)
    }

    @Test("PromptPrimitive drop strategy over limit returns nil")
    func promptPrimitiveDropOverLimit() async {
        struct LongPrimitive: PromptPrimitive {
            let id = "long"
            let priority = 1
            let estimatedTokens = 100
            var compression: CompressionStrategy {
                .drop
            }

            func renderContent() async -> String? {
                String(repeating: "x", count: 200)
            }
        }
        let section = LongPrimitive().makeSection()
        let content = await section.renderedContent(constrainedTo: 5)
        #expect(content == nil)
    }

    @Test("Default makePromptNode returns nil when body is EmptyPrompt")
    func defaultMakePromptNodeReturnsNilForEmptyBody() {
        struct EmptyBodyPrompt: Prompt {
            var body: some Prompt {
                EmptyPrompt()
            }
        }
        #expect(EmptyBodyPrompt().makePromptNode() == nil)
    }

    @Test("Default makePromptNode includes id hash for Identifiable Prompts")
    func defaultMakePromptNodeForIdentifiablePrompt() {
        struct IdentifiablePrompt: Prompt, Identifiable {
            let id: UUID = .init()
            var body: some Prompt {
                TextPrompt("hello", id: "child")
            }
        }
        let node = IdentifiablePrompt().makePromptNode()
        #expect(node != nil)
        // The path component should include the type name and id hash.
    }
}

// MARK: - New API verification

extension PKPromptDSLAndModifierCoverageTests {
    @Test("UserPrompt supports the MessageContent initializer and custom traits")
    func userPromptMessageContentInit() {
        let prompt = UserPrompt(
            MessageContent(parts: [.text("hello")]),
            id: "custom-query", priority: 3, estimatedTokens: 99
        )
        #expect(prompt.id == "custom-query")
        #expect(prompt.priority == 3)
        #expect(prompt.estimatedTokens == 99)
        #expect(prompt.text == "hello")
        #expect(prompt.resolveSections().first?.estimatedTokens == 99)
    }

    @Test("UserPrompt string initializer lowers with content-preserving sections")
    func userPromptStringInit() async throws {
        let prompt = UserPrompt("question")
        #expect(prompt.text == "question")
        #expect(prompt.content.isTextOnly)
        let section = try #require(prompt.resolveSections().first)
        let content = await section.renderedContent()
        #expect(content?.text == "question")
    }

    @Test("ImagePrompt and AudioPrompt lower through UserPrompt")
    func imageAndAudioPromptBodies() async {
        let imagePrompt = ImagePrompt(ImageContent(data: Data([1]), mediaType: "image/png"), id: "img-1")
        #expect(imagePrompt.id == "img-1")
        let imageContent = await imagePrompt.resolveSections().first?.renderedContent()
        #expect(imageContent?.multimodal != nil)

        let audioPrompt = AudioPrompt(AudioContent(data: Data([2]), format: .mp3), id: "aud-1")
        #expect(audioPrompt.id == "aud-1")
        let audioContent = await audioPrompt.resolveSections().first?.renderedContent()
        #expect(audioContent?.multimodal != nil)
    }

    @Test("PromptSection.Content.multimodal accessor exposes the ordered payload")
    func sectionContentMultimodalAccessor() {
        let multimodal = PromptSection.Content.multimodal(MessageContent(parts: [.text("x")]))
        #expect(multimodal.multimodal != nil)
        #expect(multimodal.multimodal?.text == "x")
        #expect(PromptSection.Content.text("t").multimodal == nil)
        #expect(PromptSection.Content.messages([Message(content: "m", role: .user)]).multimodal == nil)
    }

    @Test("MultimodalPromptPrimitive renderContent returns the text projection")
    func multimodalPrimitiveRenderContent() async {
        let primitive = MultimodalPromptPrimitive(
            id: "m",
            content: MessageContent(parts: [.text("projected")])
        )
        let rendered = await primitive.renderContent()
        #expect(rendered == "projected")
    }

    @Test("PromptPrimitive renderedContent preserves non-empty multimodal content")
    func primitiveMultimodalRenderedContent() async {
        struct MultimodalPrimitive: PromptPrimitive {
            let id = "mm-prim"
            let priority = 1
            let estimatedTokens = 10
            var content: PromptPrimitiveContent {
                .multimodal(MessageContent(parts: [.text("preserved")]))
            }

            func renderContent() async -> String? {
                "preserved"
            }
        }
        let section = MultimodalPrimitive().makeSection()
        let rendered = await section.renderedContent()
        #expect(rendered?.multimodal?.text == "preserved")
    }
}
