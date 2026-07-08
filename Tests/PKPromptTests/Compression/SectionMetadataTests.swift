import Foundation
import Testing
@testable import PKPrompt

@Suite("Section nodeMetadata")
struct SectionMetadataTests {
    @Test("RenderedPrompt.Section nodeMetadata hash changes when section traits change even if text stays the same")
    func renderedSectionNodeMetadataChangesWhenTraitsChange() async throws {
        let promptA = try await AnyPrompt.build {
            TextPrompt(
                "Same",
                id: "system",
                priority: 0,
                cachePolicy: .stable,
                estimatedTokens: 10
            )
        }.assemblePrompt().render()

        let promptB = try await AnyPrompt.build {
            TextPrompt(
                "Same",
                id: "system",
                priority: 10,
                cachePolicy: .stable,
                estimatedTokens: 10
            )
        }.assemblePrompt().render()

        let sectionA = try #require(promptA.sections.first)
        let sectionB = try #require(promptB.sections.first)
        let metadataA = sectionA.nodeMetadata(
            renderedContent: promptA.sectionsByID[sectionA.id] ?? ""
        )
        let metadataB = sectionB.nodeMetadata(
            renderedContent: promptB.sectionsByID[sectionB.id] ?? ""
        )

        #expect(metadataA != metadataB)
        #expect(metadataA.path == metadataB.path)
    }

    @Test("PromptSection nodeMetadata hash changes when section traits change even if text stays the same")
    func promptSectionNodeMetadataChangesWhenTraitsChange() async throws {
        let promptA = try AnyPrompt.build {
            TextPrompt(
                "Same",
                id: "system",
                priority: 0,
                cachePolicy: .stable,
                estimatedTokens: 10
            )
        }.assemblePrompt()

        let promptB = try AnyPrompt.build {
            TextPrompt(
                "Same",
                id: "system",
                priority: 10,
                cachePolicy: .stable,
                estimatedTokens: 10
            )
        }.assemblePrompt()

        let sectionA = try #require(promptA.sections.first)
        let sectionB = try #require(promptB.sections.first)
        let metadataA = sectionA.nodeMetadata(renderedContent: "Same")
        let metadataB = sectionB.nodeMetadata(renderedContent: "Same")

        #expect(metadataA != metadataB)
        #expect(metadataA.path == metadataB.path)
    }

    @Test("PromptSection and RenderedPrompt.Section produce the same nodeMetadata for equivalent inputs")
    func promptSectionAndRenderedSectionProduceSameNodeMetadata() async throws {
        let assembled = try AnyPrompt.build {
            TextPrompt(
                "Content",
                id: "system",
                priority: 5,
                cachePolicy: .stable,
                estimatedTokens: 10
            )
        }.assemblePrompt()
        let rendered = await assembled.render()

        let promptSection = try #require(assembled.sections.first)
        let renderedSection = try #require(rendered.sections.first)
        let content = "Content"

        let metadataFromPromptSection = promptSection.nodeMetadata(renderedContent: content)
        let metadataFromRenderedSection = renderedSection.nodeMetadata(renderedContent: content)

        #expect(metadataFromPromptSection == metadataFromRenderedSection)
    }
}
