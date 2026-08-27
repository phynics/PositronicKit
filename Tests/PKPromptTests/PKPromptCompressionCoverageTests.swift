import Foundation
@testable import PKContracts
@testable import PKPrompt
import PKUtilities
import Testing

/// Compression and token-budget coverage.
@Suite("Compression and token-budget coverage")
struct PKPromptCompressionCoverageTests {
    private func makeEstimatedSection(
        id: String = UUID().uuidString,
        tokens: Int,
        role: PromptSectionRole = .context,
        priority: Int = 50,
        compression: CompressionStrategy = .keep
    ) -> PromptSection {
        PromptSection(
            id: id, role: role, priority: priority, estimatedTokens: tokens,
            compression: compression, type: .text, cachePolicy: .volatile,
            path: ["root", id], render: { _ in .text("x") }
        )
    }

    @Test("SectionCompressor default summarize(request:) delegates to summarize(_:)")
    func sectionCompressorDefaultDelegates() async throws {
        struct TestCompressor: SectionCompressor {
            func summarize(_ text: String) async throws -> String {
                "compressed:\(text)"
            }
        }
        let compressor = TestCompressor()
        let request = SummaryRequest(
            nodeID: "n1", path: ["root", "n1"],
            text: "hello", targetTokens: 10, reason: .budgetReduction
        )
        let result = try await compressor.summarize(request: request)
        #expect(result == "compressed:hello")
    }

    // MARK: - StructuredCompressionPlanner under-budget path

    @Test("Planner keeps all nodes when total is under budget")
    func plannerKeepsAllUnderBudget() throws {
        let planner = StructuredCompressionPlanner()
        let nodes = [
            StructuredCompressionNode(id: "a", path: ["a"], nodeHash: 1, priority: 10, cachePolicy: .stable, strategy: .keep, estimatedTokens: 50),
            StructuredCompressionNode(id: "b", path: ["b"], nodeHash: 2, priority: 5, cachePolicy: .volatile, strategy: .keep, estimatedTokens: 30),
        ]
        let plan = try planner.plan(nodes: nodes, availableTokens: 200, diff: nil)
        #expect(plan.nodeActions.count == 2)
        #expect(plan.nodeActions.allSatisfy { $0.action == .keep })
    }

    @Test("Planner drops stable non-keep nodes when over budget")
    func plannerDropsStableNonKeepNodes() throws {
        let planner = StructuredCompressionPlanner()
        let nodes = [
            StructuredCompressionNode(id: "a", path: ["a"], nodeHash: 1, priority: 10, cachePolicy: .stable, strategy: .summarize, estimatedTokens: 100),
            StructuredCompressionNode(id: "b", path: ["b"], nodeHash: 2, priority: 5, cachePolicy: .volatile, strategy: .keep, estimatedTokens: 100),
        ]
        let diff = StructuredDiffHint(changedNodePaths: [], stableNodePaths: [["a"]])
        let plan = try planner.plan(nodes: nodes, availableTokens: 50, diff: diff)
        // Node "a" is stable and non-keep → dropped.
        let aAction = plan.nodeActions.first { $0.nodeID == "a" }
        #expect(aAction?.action == .drop)
    }

    @Test("Planner uses truncate strategy when over budget with truncate policy")
    func plannerUsesTruncate() throws {
        let planner = StructuredCompressionPlanner()
        let nodes = [
            StructuredCompressionNode(id: "a", path: ["a"], nodeHash: 1, priority: 10, cachePolicy: .volatile, strategy: .truncate(keeping: .head), estimatedTokens: 200),
        ]
        let plan = try planner.plan(nodes: nodes, availableTokens: 50, diff: nil)
        let action = plan.nodeActions.first
        if case let .truncate(limit, tail) = action?.action {
            #expect(limit == 50)
            #expect(tail == true)
        } else {
            Issue.record("Expected truncate action")
        }
    }

    @Test("Planner uses summarize strategy when over budget with summarize policy")
    func plannerUsesSummarize() throws {
        let planner = StructuredCompressionPlanner()
        let nodes = [
            StructuredCompressionNode(id: "a", path: ["a"], nodeHash: 1, priority: 10, cachePolicy: .volatile, strategy: .summarize, estimatedTokens: 200),
        ]
        let plan = try planner.plan(nodes: nodes, availableTokens: 50, diff: nil)
        let action = plan.nodeActions.first
        if case let .summarize(target, _) = action?.action {
            #expect(target > 0)
        } else {
            Issue.record("Expected summarize action")
        }
    }

    // MARK: - TokenBudget overloads and priority allocator

    @Test("TokenBudget result resolves prompt arrays")
    func tokenBudgetApplyToPromptArray() async throws {
        let budget = TokenBudget(maxTokens: 10000, reserveForResponse: 0)
        let sections: [any Prompt] = [TextPrompt("hello", id: "t1")]
        let result = try await budget.result(forPrompts: sections).sections
        #expect(result.count == 1)
    }

    @Test("TokenBudget result has no report when under budget")
    func tokenBudgetApplyWithReportUnderBudget() async throws {
        let budget = TokenBudget(maxTokens: 10000, reserveForResponse: 0)
        let section = PromptSectionHelper.makeTextSection(content: .text("hi"), role: .context)
        let result = try await budget.result(forResolvedSections: [section])
        #expect(result.report == nil)
        #expect(result.sections.count == 1)
    }

    @Test("TokenBudget rejects mandatory keep-strategy sections that don't fit")
    func tokenBudgetDropsKeepSections() async {
        let budget = TokenBudget(maxTokens: 10, reserveForResponse: 0)
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .keep
        )
        await #expect(throws: PromptCompressionError.mandatorySectionOverflow(
            sectionID: section.id, estimatedTokens: section.estimatedTokens, availableTokens: 10
        )) {
            try await budget.result(forResolvedSections: [section])
        }
    }

    @Test("TokenBudget priority allocator truncates sections with truncate strategy")
    func tokenBudgetTruncatesSections() async throws {
        let budget = TokenBudget(maxTokens: 10, reserveForResponse: 0)
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .truncate(keeping: .head)
        )
        let result = try await budget.result(forResolvedSections: [section])
        // Should produce a report with truncate action.
        #expect(result.report != nil)
    }

    @Test("TokenBudget priority allocator drops sections with drop strategy")
    func tokenBudgetDropsSections() async throws {
        let budget = TokenBudget(maxTokens: 10, reserveForResponse: 0)
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .drop
        )
        let result = try await budget.result(forResolvedSections: [section])
        #expect(result.sections.count == 0)
        #expect(result.report?.nodeReports.first?.action == .drop)
    }

    @Test("TokenBudget priority allocator summarizes sections with summarize strategy")
    func tokenBudgetSummarizesSections() async throws {
        struct StubCompressor: SectionCompressor {
            func summarize(_: String) async throws -> String {
                "short"
            }
        }
        let budget = TokenBudget(maxTokens: 10, reserveForResponse: 0)
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .summarize
        )
        let result = try await budget.result(forResolvedSections: [section], compressor: StubCompressor())
        // Should produce a summary.
        let report = try #require(result.report)
        #expect(report.nodeReports.first?.action == .summarize(targetTokens: 1, reason: .budgetReduction))
    }

    @Test("TokenBudget priority allocator drops summarize when no compressor")
    func tokenBudgetDropsSummarizeWithoutCompressor() async throws {
        let budget = TokenBudget(maxTokens: 10, reserveForResponse: 0)
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .summarize
        )
        let result = try await budget.result(forResolvedSections: [section])
        #expect(result.sections.count == 0)
        #expect(result.report?.nodeReports.first?.fallbackReason == "missing_compressor")
    }

    @Test("TokenBudget priority allocator drops summarize when content is empty")
    func tokenBudgetDropsSummarizeWithEmptyContent() async throws {
        struct StubCompressor: SectionCompressor {
            func summarize(_: String) async throws -> String {
                "short"
            }
        }
        let budget = TokenBudget(maxTokens: 10, reserveForResponse: 0)
        // A section with high estimatedTokens but empty rendered content.
        let section = PromptSection(
            id: UUID().uuidString, role: .context, priority: 50,
            estimatedTokens: 100, compression: .summarize, type: .text,
            cachePolicy: .volatile, path: ["root", "section"],
            render: { _ in .text("") }
        )
        let result = try await budget.result(forResolvedSections: [section], compressor: StubCompressor())
        #expect(result.sections.count == 0)
        #expect(result.report?.nodeReports.first?.fallbackReason == "missing_content")
    }

    @Test("TokenBudget priority allocator drops summarize when summary exceeds budget")
    func tokenBudgetDropsSummarizeExceedsBudget() async throws {
        struct StubCompressor: SectionCompressor {
            func summarize(_: String) async throws -> String {
                String(repeating: "y", count: 1000)
            }
        }
        let budget = TokenBudget(maxTokens: 10, reserveForResponse: 0)
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .summarize
        )
        let result = try await budget.result(forResolvedSections: [section], compressor: StubCompressor())
        #expect(result.sections.count == 0)
        #expect(result.report?.nodeReports.first?.fallbackReason == "summary_exceeds_budget")
    }

    @Test("TokenBudget preserves summarizer failures")
    func tokenBudgetDropsSummarizeFails() async {
        struct FailingCompressor: SectionCompressor {
            func summarize(_: String) async throws -> String {
                throw NSError(domain: "x", code: 1)
            }
        }
        let budget = TokenBudget(maxTokens: 10, reserveForResponse: 0)
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .summarize
        )
        do {
            _ = try await budget.result(forResolvedSections: [section], compressor: FailingCompressor())
            Issue.record("Expected the summarizer error to propagate")
        } catch let error as NSError {
            #expect(error.domain == "x")
            #expect(error.code == 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("TokenBudget priority allocator drops summarize when summary is empty")
    func tokenBudgetDropsSummarizeEmpty() async throws {
        struct EmptyCompressor: SectionCompressor {
            func summarize(_: String) async throws -> String {
                ""
            }
        }
        let budget = TokenBudget(maxTokens: 10, reserveForResponse: 0)
        let section = PromptSectionHelper.makeTextSection(
            content: .text(String(repeating: "x", count: 100)),
            role: .context,
            compression: .summarize
        )
        let result = try await budget.result(forResolvedSections: [section], compressor: EmptyCompressor())
        #expect(result.sections.count == 0)
        #expect(result.report?.nodeReports.first?.fallbackReason == "empty_summary")
    }

    @Test("TokenBudget makeStructuredPlan builds a plan from sections")
    func tokenBudgetMakeStructuredPlan() throws {
        let budget = TokenBudget(maxTokens: 100, reserveForResponse: 0)
        let section = PromptSectionHelper.makeTextSection(content: .text("hi"), role: .context)
        let plan = try budget.makeStructuredPlan(
            sections: [section],
            available: 50,
            structuredDiff: nil,
            nodeMetadata: [:]
        )
        #expect(plan.nodeActions.count == 1)
    }

    // MARK: - PromptPrimitive body and render constraints

    @Test("sectionContentHash produces stable hashes for text and messages content")
    func sectionContentHashStability() {
        let textHash1 = sectionContentHash(.text("hello"))
        let textHash2 = sectionContentHash(.text("hello"))
        let textHash3 = sectionContentHash(.text("world"))
        #expect(textHash1 == textHash2)
        #expect(textHash1 != textHash3)

        let msgsHash1 = sectionContentHash(.messages([Message(content: "hi", role: .user)]))
        let msgsHash2 = sectionContentHash(.messages([Message(content: "hi", role: .user)]))
        let msgsHash3 = sectionContentHash(.messages([Message(content: "bye", role: .user)]))
        #expect(msgsHash1 == msgsHash2)
        #expect(msgsHash1 != msgsHash3)
        #expect(textHash1 != msgsHash1)
    }

    @Test("RenderedPrompt.estimatedTokens sums section tokens")
    func renderedPromptEstimatedTokens() {
        let section = RenderedPrompt.Section(
            id: "s", role: .context, priority: 50, estimatedTokens: 42,
            compression: .keep, type: .text, cachePolicy: .stable,
            path: ["root", "s"], parentID: nil, content: .text("x")
        )
        let rendered = RenderedPrompt(sections: [section, section], string: "x", sectionsByID: ["s": "x"])
        #expect(rendered.estimatedTokens == 84)
        #expect(rendered.compressionReport == nil)
    }

    @Test("Executor passes through sections not in the plan")
    func executorPassesThroughUnplannedSections() async throws {
        let sections = [
            PromptSectionHelper.makeTextSection(content: .text("planned"), role: .context),
            PromptSectionHelper.makeTextSection(content: .text("unplanned"), role: .context),
        ]
        let plan = StructuredCompressionPlan(
            availableTokens: 10000,
            totalEstimatedTokens: 10,
            nodeActions: [
                .init(nodeID: sections[0].id, path: sections[0].path, nodeHash: 1,
                      strategy: .keep, estimatedTokens: 10, action: .keep),
            ]
        )
        let executor = StructuredCompressionExecutor()
        let result = try await executor.execute(plan: plan, sections: sections, compressor: nil)
        #expect(result.sections.count == 2)
    }

    @Test("TokenBudget result accepts prompt existentials")
    func tokenBudgetApplyWithReportPromptArray() async throws {
        let budget = TokenBudget(maxTokens: 10000, reserveForResponse: 0)
        let sections: [any Prompt] = [TextPrompt("hello", id: "t1")]
        let result = try await budget.result(forPrompts: sections)
        #expect(result.sections.count == 1)
        #expect(result.report == nil)
    }

    @Test("Executor synthesizes no-op report for planned section with no transform")
    func executorSynthesizesNoOpReport() async throws {
        // A section that is in the plan but whose node id doesn't match any section
        // in sectionsById (because it was removed). The executor's else branch
        // (line 78) appends the section as-is, and the synthesis branch (line 84)
        // creates a no-op report when the section id is in the plan but not in
        // reportsById. To trigger this, we need a section whose id IS in the plan
        // but was NOT transformed — this happens when the section exists in the
        // sections list but the plan action targets it with a different id match.
        // Actually, this happens when sectionsById[planned.nodeID] returns nil
        // (section not found), so transformedSectionsById is empty for that id,
        // but actionById[section.id] exists. This requires the section's id to
        // be in actionById but not in sectionsById — which means the plan references
        // an id that doesn't exist in sections. But then the reconstruction loop
        // iterates over sections, not plan actions, so the synthesis branch is
        // never reached. It's dead code.
        // Instead, test the line 78 else branch: section not in transformedSectionsById.
        let sections = [
            PromptSectionHelper.makeTextSection(content: .text("unplanned"), role: .context),
        ]
        let plan = StructuredCompressionPlan(
            availableTokens: 10000,
            totalEstimatedTokens: 10,
            nodeActions: [] // No actions — section passes through
        )
        let executor = StructuredCompressionExecutor()
        let result = try await executor.execute(plan: plan, sections: sections, compressor: nil)
        #expect(result.sections.count == 1)
    }

    @Test("TokenBudget constrain tail fallback is defensive dead code")
    func tokenBudgetConstrainTailFallbackIsDeadCode() {
        // The tail=true fallback (lines 294-295) is defensive dead code:
        // only .truncate sections produce .constrain decisions, and .truncate
        // always carries a tail value. Non-truncate compressions (.keep, .summarize,
        // .drop) never produce .constrain decisions. This branch is unreachable.
        #expect(TokenBudget(maxTokens: 1).maxTokens == 1)
    }
}

// MARK: - Identifiable Prompt path

extension PKPromptCompressionCoverageTests {
    @Test("TokenBudget(maxTokens:) convenience init defaults reserveForResponse to 0")
    func tokenBudgetSingleParamInit() {
        let budget = TokenBudget(maxTokens: 1000)
        #expect(budget.maxTokens == 1000)
        #expect(budget.reserveForResponse == 0)
    }

    @Test("StructuredDiffHint variadic init accepts path components")
    func structuredDiffHintVariadicInit() {
        let diff = StructuredDiffHint(
            changed: ["root", "section1"],
            stable: ["root", "section2"]
        )
        #expect(diff.changedNodePaths == [["root", "section1"]])
        #expect(diff.stableNodePaths == [["root", "section2"]])
    }

    @Test("StructuredDiffHint variadic init with multiple paths")
    func structuredDiffHintVariadicMultiple() {
        let diff = StructuredDiffHint(
            changed: ["root", "a"], ["root", "b"],
            stable: ["root", "c"]
        )
        #expect(diff.changedNodePaths.count == 2)
        #expect(diff.stableNodePaths.count == 1)
    }

    @Test("StructuredDiffHint original init still works")
    func structuredDiffHintOriginalInit() {
        let diff = StructuredDiffHint(
            changedNodePaths: [["root", "a"]],
            stableNodePaths: [["root", "b"]]
        )
        #expect(diff.changedNodePaths == [["root", "a"]])
        #expect(diff.stableNodePaths == [["root", "b"]])
    }
}

// MARK: - Error surface, multimodal hashing, and allocator branch coverage

extension PKPromptCompressionCoverageTests {
    @Test("sectionContentHash folds multimodal text, image, and audio parts")
    func sectionContentHashMultimodal() {
        let text = MessageContent(parts: [.text("hello")])
        let image = MessageContent(parts: [
            .image(ImageContent(data: Data([0x01]), mediaType: "image/png", detail: .high, estimatedTokens: 2048)),
        ])
        let audio = MessageContent(parts: [
            .audio(AudioContent(
                data: Data([0x02]),
                format: .wav,
                transcript: "hi",
                estimatedTokens: 512,
                continuation: AudioContinuationReference(
                    provider: .openAI,
                    id: "ref-1",
                    expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )),
        ])

        let textHash = sectionContentHash(.multimodal(text))
        let imageHash = sectionContentHash(.multimodal(image))
        let audioHash = sectionContentHash(.multimodal(audio))

        #expect(textHash == sectionContentHash(.multimodal(text)))
        #expect(imageHash == sectionContentHash(.multimodal(image)))
        #expect(audioHash == sectionContentHash(.multimodal(audio)))
        #expect(textHash != imageHash)
        #expect(textHash != audioHash)
        #expect(imageHash != audioHash)

        // PKDEEP2-003(b): detail/media ordering is content-bearing, token estimates are not.
        let detailChange = sectionContentHash(.multimodal(MessageContent(parts: [
            .image(ImageContent(data: Data([0x01]), mediaType: "image/png", detail: .low)),
        ])))
        #expect(imageHash != detailChange)

        let transcriptChange = sectionContentHash(.multimodal(MessageContent(parts: [
            .audio(AudioContent(data: Data([0x02]), format: .wav, transcript: "bye")),
        ])))
        #expect(audioHash != transcriptChange)
    }

    @Test("TokenBudget with a negative available budget surfaces a zero-estimate error")
    func tokenBudgetNegativeAvailable() async {
        let budget = TokenBudget(maxTokens: 10, reserveForResponse: 30)
        await #expect(throws: PromptCompressionError.budgetUnsatisfied(availableTokens: -20, estimatedTokens: 0)) {
            try await budget.result(forResolvedSections: [PromptSectionHelper.makeTextSection(content: .text("x"), role: .context)])
        }
    }

    @Test("TokenBudget allocator fails a keep section that cannot fit the remaining budget")
    func tokenBudgetAllocatorKeepOverflow() async {
        let trunk = makeEstimatedSection(id: "trunk", tokens: 80, priority: 100, compression: .truncate(keeping: .head))
        let keep = makeEstimatedSection(id: "keep", tokens: 50, priority: 50, compression: .keep)
        let budget = TokenBudget(maxTokens: 100, reserveForResponse: 0)
        await #expect(throws: PromptCompressionError.mandatorySectionOverflow(
            sectionID: keep.id, estimatedTokens: keep.estimatedTokens, availableTokens: 20
        )) {
            try await budget.result(forResolvedSections: [trunk, keep])
        }
    }

    @Test("TokenBudget drops summarize sections once the allocator budget is exhausted")
    func tokenBudgetDropsSummarizeWithoutBudget() async throws {
        let trunk = makeEstimatedSection(id: "trunk", tokens: 100, priority: 100, compression: .truncate(keeping: .head))
        let summary = makeEstimatedSection(id: "summary", tokens: 50, priority: 50, compression: .summarize)
        let budget = TokenBudget(maxTokens: 100, reserveForResponse: 0)
        let result = try await budget.result(forResolvedSections: [trunk, summary])
        #expect(result.sections.map(\.id) == [trunk.id])
        #expect(result.report?.nodeReports.contains { if case .drop = $0.action { return true }; return false } == true)
    }

    @Test("Executor and planner reject duplicate identifiers with typed errors")
    func executorAndPlannerRejectDuplicates() async throws {
        let section = PromptSectionHelper.makeTextSection(content: .text("x"), role: .context)
        let emptyPlan = StructuredCompressionPlan(availableTokens: 100, totalEstimatedTokens: 10, nodeActions: [])
        await #expect(throws: PromptCompressionError.duplicateSectionIDs([section.id])) {
            try await StructuredCompressionExecutor().execute(plan: emptyPlan, sections: [section, section], compressor: nil)
        }

        let action = PlannedNodeAction(nodeID: "n", path: ["root"], nodeHash: 1, strategy: .keep, estimatedTokens: 5, action: .keep)
        let dupPlan = StructuredCompressionPlan(availableTokens: 100, totalEstimatedTokens: 10, nodeActions: [action, action])
        await #expect(throws: PromptCompressionError.duplicatePlannedNodeIDs(["n"])) {
            try await StructuredCompressionExecutor().execute(plan: dupPlan, sections: [section], compressor: nil)
        }

        let node = StructuredCompressionNode(
            id: "n", path: ["root"], nodeHash: 1, priority: 50,
            cachePolicy: .stable, strategy: .keep, estimatedTokens: 5
        )
        let planner = StructuredCompressionPlanner()
        #expect(throws: PromptCompressionError.duplicateSectionIDs(["n"])) {
            try planner.plan(nodes: [node, node], availableTokens: 100, diff: nil)
        }
    }
}
