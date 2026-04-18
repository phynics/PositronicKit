import Foundation
import Testing
@testable import PKPrompt

@Suite("Prompt section validation")
struct PromptSectionValidationTests {
    private struct MockSection: PromptLeaf {
        let id: String
        let priority: Int = 0
        let estimatedTokens: Int = 1
        let type: PromptSectionType = .text

        func renderContent() async -> String? {
            id
        }
    }

    private func makeResolvedSection(id: String) -> ResolvedPromptSection {
        ResolvedPromptSection(
            id: id,
            role: .context,
            priority: 0,
            estimatedTokens: 1,
            compression: .keep,
            type: .text,
            cachePolicy: .volatile,
            path: [id],
            render: { _ in id }
        )
    }

    @Test("Validator rejects duplicate ids in resolved sections")
    func validatorRejectsDuplicateResolvedSectionIDs() throws {
        let sections = [makeResolvedSection(id: "dup"), makeResolvedSection(id: "dup")]

        #expect(throws: PromptSectionValidationError.duplicateSectionIDs(["dup"])) {
            try PromptSectionValidator.validateUniqueIDs(in: sections)
        }
    }

    @Test("Validator rejects duplicate ids in composite sections")
    func validatorRejectsDuplicateCompositeSectionIDs() throws {
        let sections: [any PromptComposite] = [MockSection(id: "dup"), MockSection(id: "dup")]

        #expect(throws: PromptSectionValidationError.duplicateSectionIDs(["dup"])) {
            try PromptSectionValidator.validateUniqueIDs(in: sections)
        }
    }

    @Test("Validator reports sorted duplicate ids")
    func validatorReportsSortedDuplicateIDs() {
        let sections = [
            makeResolvedSection(id: "b"),
            makeResolvedSection(id: "a"),
            makeResolvedSection(id: "b"),
            makeResolvedSection(id: "a"),
        ]

        #expect(PromptSectionValidator.duplicateIDs(in: sections) == ["a", "b"])
    }
}
