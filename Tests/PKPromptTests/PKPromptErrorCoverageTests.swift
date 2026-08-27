import Foundation
@testable import PKContracts
@testable import PKPrompt
import PKUtilities
import Testing

/// Prompt error-surface coverage.
@Suite("Prompt error-surface coverage")
struct PKPromptErrorCoverageTests {
    @Test("PromptAssemblyError has correct codes and messages")
    func promptAssemblyErrorCodes() {
        #expect(PromptAssemblyError.duplicateSectionIDs(["a"]).errorCode == 1001)
        #expect(PromptAssemblyError.multipleUserQuerySections(["a"]).errorCode == 1002)
        #expect(PromptAssemblyError.duplicateSectionIDs(["a"]).errorDomain == PKErrorDomain.prompt)
    }

    @Test("PromptAssemblyError remediation is provided")
    func promptAssemblyErrorRemediation() {
        #expect(PromptAssemblyError.duplicateSectionIDs(["a"]).remediation != nil)
        #expect(PromptAssemblyError.multipleUserQuerySections(["a"]).remediation != nil)
    }

    // MARK: - ForEach

    @Test("PromptAssemblyError.multipleUserQuerySections userFriendlyMessage")
    func promptAssemblyErrorMultipleUserQuery() {
        let error = PromptAssemblyError.multipleUserQuerySections(["a", "b"])
        #expect(error.userFriendlyMessage.contains("multiple"))
        #expect(error.userFriendlyMessage.contains("a, b"))
    }

    @Test("AssembledPrompt.render formats system messages")
    func assembledPromptRendersSystem() async throws {
        let section = PromptSection(
            id: UUID().uuidString, role: .chatHistory, priority: 50,
            estimatedTokens: 10, compression: .keep, type: .text,
            cachePolicy: .volatile, path: ["root", "s"],
            render: { _ in .messages([Message(content: "system msg", role: .system)]) }
        )
        let rendered = try await AssembledPrompt(sections: [section]).render()
        #expect(rendered.string.contains("System: system msg"))
    }
}

// MARK: - Last 3 gaps

extension PKPromptErrorCoverageTests {
    @Test("PromptCompressionError exposes typed fields for every case")
    func promptCompressionErrorAccessors() {
        let cases: [(PromptCompressionError, Int)] = [
            (.duplicateSectionIDs(["a", "b"]), 1201),
            (.duplicatePlannedNodeIDs(["n"]), 1202),
            (.budgetUnsatisfied(availableTokens: 10, estimatedTokens: 40), 1203),
            (.mandatorySectionOverflow(sectionID: "s", estimatedTokens: 40, availableTokens: 10), 1204),
        ]
        for (error, code) in cases {
            #expect(error.errorDomain == PKErrorDomain.prompt)
            #expect(error.errorCode == code)
            #expect(!error.userFriendlyMessage.isEmpty)
            #expect(error.remediation != nil)
        }
        #expect(TokenBudgetError.nonPositiveContextWindow(0).errorCode == 1101)
    }

    @Test("PromptJournalValidationError exposes typed fields for both cases")
    func promptJournalValidationErrorAccessors() {
        let cases: [(PromptJournal.ValidationError, Int)] = [
            (.duplicateStableSectionIDs(["a"]), 1301),
            (.duplicateSemiStableSectionIDs(["b"]), 1302),
        ]
        for (error, code) in cases {
            #expect(error.errorDomain == PKErrorDomain.prompt)
            #expect(error.errorCode == code)
            #expect(!error.userFriendlyMessage.isEmpty)
            #expect(error.remediation != nil)
        }
    }

    @Test("TokenBudgetError messages and remediation for reserve failures")
    func tokenBudgetErrorReserveAccessors() {
        let negative = TokenBudgetError.negativeOutputReserve(-5)
        #expect(negative.userFriendlyMessage.contains("-5"))
        #expect(negative.remediation != nil)
        #expect(negative.errorCode == 1102)

        let exceeds = TokenBudgetError.outputReserveExceedsContextWindow(contextWindow: 10, reserve: 10)
        #expect(exceeds.userFriendlyMessage.contains("10"))
        #expect(exceeds.remediation != nil)
        #expect(exceeds.errorCode == 1103)
    }

    @Test("AssembledPrompt renders multimodal sections via the text projection")
    func assembledPromptRendersMultimodal() async throws {
        let content = MessageContent(parts: [
            .text("multimodal text"),
            .image(ImageContent(data: Data([1]), mediaType: "image/png")),
        ])
        let section = PromptSection(
            id: UUID().uuidString, role: .context, priority: 50,
            estimatedTokens: 10, compression: .keep, type: .text,
            cachePolicy: .volatile, path: ["root", "s"],
            render: { _ in .multimodal(content) }
        )
        let rendered = try await AssembledPrompt(sections: [section]).render()
        #expect(rendered.string.contains("multimodal text"))
    }
}
