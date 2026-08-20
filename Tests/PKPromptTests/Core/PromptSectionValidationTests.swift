import Foundation
@testable import PKPrompt
import PKContracts
import PKUtilities
import Testing

@Suite("Prompt section validation")
struct PromptSectionValidationTests {
    private struct IdentifiableValue: Identifiable {
        let id: String
    }

    private struct KeyedValue {
        let key: String
    }

    private struct MockSection: PromptPrimitive {
        let id: String
        let priority: Int = 0
        let estimatedTokens: Int = 1
        let type: PromptSectionType = .text

        func renderContent() async -> String? {
            id
        }
    }

    private struct DuplicateSectionsPrompt: Prompt {
        var body: some Prompt {
            AnyPrompt {
                MockSection(id: "dup")
                MockSection(id: "dup")
            }
        }
    }

    private func makeResolvedSection(id: String) -> PromptSection {
        PromptSection(
            id: id,
            role: .context,
            priority: 0,
            estimatedTokens: 1,
            compression: .keep,
            type: .text,
            cachePolicy: .volatile,
            path: [id],
            render: { _ in .text(id) }
        )
    }

    @Test("AssembledPrompt rejects duplicate ids in resolved sections")
    func assembledPromptRejectsDuplicateResolvedSectionIDs() throws {
        let sections = [makeResolvedSection(id: "dup"), makeResolvedSection(id: "dup")]

        #expect(throws: AssembledPrompt.ValidationError.duplicateSectionIDs(["dup"])) {
            try AssembledPrompt(sections: sections)
        }
    }

    @Test("Prompt assembledPrompt surfaces validation errors")
    func promptAssembledPromptSurfacesValidationErrors() throws {
        #expect(throws: AssembledPrompt.ValidationError.duplicateSectionIDs(["dup"])) {
            try DuplicateSectionsPrompt().assemblePrompt()
        }
    }

    @Test("Prompt renderToString surfaces validation errors instead of swallowing them")
    func promptRenderToStringSurfacesValidationErrors() async throws {
        await #expect(throws: AssembledPrompt.ValidationError.duplicateSectionIDs(["dup"])) {
            _ = try await DuplicateSectionsPrompt().renderToString()
        }
    }

    @Test("Prompt assembly errors expose PKError metadata")
    func promptAssemblyErrorsExposePKErrorMetadata() {
        let error = PromptAssemblyError.duplicateSectionIDs(["alpha", "beta"])

        #expect(error.errorDomain == PKErrorDomain.prompt)
        #expect(error.errorCode == 1001)
        #expect(
            error.userFriendlyMessage ==
                "Prompt assembly found duplicate section identifiers: alpha, beta."
        )
        #expect(error.remediation == "Ensure each prompt section uses a unique stable identifier.")
    }

    @Test("Prompt rejects duplicate ids in composite sections")
    func promptRejectsDuplicateCompositeSectionIDs() {
        let sections: [any Prompt] = [MockSection(id: "dup"), MockSection(id: "dup")]

        let duplicateIDs = sections
            .flatMap { try! $0.assemblePrompt().sections }
            .duplicateIDs(idKeyPath: \PromptSection.id)

        #expect(duplicateIDs == ["dup"])
    }

    @Test("Collection helper reports sorted duplicate ids")
    func collectionReportsSortedDuplicateIDs() {
        let sections = [
            makeResolvedSection(id: "b"),
            makeResolvedSection(id: "a"),
            makeResolvedSection(id: "b"),
            makeResolvedSection(id: "a"),
        ]

        #expect(sections.duplicateIDs(idKeyPath: \.id) == ["a", "b"])
    }

    @Test("Collection uniqueness lookup uses Identifiable ids")
    func collectionDuplicateIDsForIdentifiable() {
        let values = [IdentifiableValue(id: "b"), IdentifiableValue(id: "a"), IdentifiableValue(id: "b")]

        #expect(values.duplicateIDs(idKeyPath: \.id) == ["b"])
    }

    @Test("Collection uniqueness lookup uses explicit key path")
    func collectionDuplicateIDsForExplicitKeyPath() {
        let values = [KeyedValue(key: "b"), KeyedValue(key: "a"), KeyedValue(key: "a")]

        #expect(values.duplicateIDs(idKeyPath: \.key) == ["a"])
    }
}
