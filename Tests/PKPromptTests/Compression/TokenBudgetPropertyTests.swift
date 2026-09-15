import Foundation
import Testing

@testable import PKPrompt
import PKTestSupport

/// Budgeting/compression property for `TokenBudget` (issue #155).
///
/// Invariants, over seeded section sets and budgets:
/// - the result never exceeds the available budget;
/// - a `.keep` (required) section is never dropped — over-budget mandatory content throws
///   `mandatorySectionOverflow` instead;
/// - identical input yields identical output (deterministic);
/// - duplicate section IDs always throw.
/// Bounded (`defaultCaseCount` cases) and deterministic under a fixed seed
/// (`PK_GENERATIVE_SEED` overrides; failures report the seed).
@Suite("TokenBudget property", .tags(.generative))
struct TokenBudgetPropertyTests {
    private let seed = GenerativeConfig.effectiveSeed()
    private let caseCount = GenerativeConfig.defaultCaseCount

    private struct StubCompressor: SectionCompressor {
        func summarize(_ text: String) async throws -> String {
            "s"
        }
    }

    private func makeSection(id: String, priority: Int, tokens: Int, compression: CompressionStrategy) -> PromptSection {
        PromptSection(
            id: id,
            role: .context,
            priority: priority,
            estimatedTokens: tokens,
            compression: compression,
            type: .text,
            cachePolicy: .volatile,
            path: ["volatile", id],
            render: { _ in .text(String(repeating: "x ", count: max(1, tokens))) }
        )
    }

    private func generatedCases(count: Int, seed: UInt64) -> [([PromptSection], TokenBudget)] {
        var rng = SeededRNG(seed: seed)
        let strategies: [CompressionStrategy] = [.keep, .truncate(tail: true), .truncate(tail: false), .summarize, .drop]
        return (0 ..< count).map { _ in
            let sectionCount = rng.nextInt(in: 1 ..< 7)
            // Small ID pool so duplicates arise naturally some of the time.
            let sections = (0 ..< sectionCount).map { _ in
                makeSection(
                    id: "s\(rng.nextInt(upperBound: 5))",
                    priority: rng.nextElement([25, 50, 75, 100]),
                    tokens: rng.nextInt(upperBound: 51),
                    compression: rng.nextElement(strategies)
                )
            }
            let maxTokens = rng.nextInt(upperBound: 121)
            let reserve = maxTokens == 0 ? 0 : rng.nextInt(upperBound: maxTokens + 1)
            return (sections, TokenBudget(maxTokens: maxTokens, reserveForResponse: reserve))
        }
    }

    @Test("result respects the budget and keeps required sections")
    func budgetInvariants() async {
        for (caseIndex, (sections, budget)) in generatedCases(count: caseCount, seed: seed).enumerated() {
            let context = "seed=\(seed) case#\(caseIndex) budget=\(budget.maxTokens)/\(budget.reserveForResponse)"
            let duplicateIDs = Set(sections.map(\.id)).count != sections.count
            do {
                let result = try await budget.result(forResolvedSections: sections, compressor: StubCompressor())
                #expect(!duplicateIDs, "\(context): duplicate IDs must throw, not succeed")
                #expect(
                    result.estimatedTokens <= result.availableTokens,
                    "\(context): estimated \(result.estimatedTokens) exceeds available \(result.availableTokens)"
                )
                let keptIDs = Set(result.sections.map(\.id))
                for section in sections where section.compression == .keep {
                    #expect(keptIDs.contains(section.id), "\(context): required section \(section.id) was dropped")
                }
                // Determinism: identical input, identical output.
                let again = try await budget.result(forResolvedSections: sections, compressor: StubCompressor())
                #expect(
                    again.sections.map(\.id) == result.sections.map(\.id)
                        && again.estimatedTokens == result.estimatedTokens,
                    "\(context): nondeterministic result"
                )
            } catch let error as PromptCompressionError {
                switch error {
                case .duplicateSectionIDs:
                    #expect(duplicateIDs, "\(context): duplicate error without duplicates")
                case .mandatorySectionOverflow, .budgetUnsatisfied:
                    break // Legal over-budget outcomes: never silently drop `.keep`.
                }
            } catch {
                Issue.record("\(context): unexpected error \(error)")
            }
        }
    }

    @Test("section ordering and duplicates: unique IDs never throw duplicate error")
    func uniqueIDsNeverDuplicateThrow() async {
        var rng = SeededRNG(seed: seed ^ 0xD0711C47)
        for iteration in 0 ..< caseCount {
            let count = rng.nextInt(in: 1 ..< 7)
            let sections = (0 ..< count).map { i in
                makeSection(id: "u\(iteration)-\(i)", priority: 50, tokens: rng.nextInt(upperBound: 20), compression: .drop)
            }
            let budget = TokenBudget(maxTokens: rng.nextInt(upperBound: 200))
            do {
                _ = try await budget.result(forResolvedSections: sections, compressor: StubCompressor())
            } catch let error as PromptCompressionError {
                if case .duplicateSectionIDs = error {
                    Issue.record("seed=\(seed) iter#\(iteration): unique IDs threw duplicate error")
                }
            }
        }
    }

    // MARK: - Committed regression fixtures

    /// Duplicate section IDs are rejected even when the prompt fits the budget.
    @Test("regression: duplicate section IDs throw")
    func duplicateIDsThrow() async {
        let sections = [
            makeSection(id: "dup", priority: 50, tokens: 5, compression: .keep),
            makeSection(id: "dup", priority: 50, tokens: 5, compression: .keep),
        ]
        await #expect(throws: PromptCompressionError.self) {
            try await TokenBudget(maxTokens: 100).result(forResolvedSections: sections, compressor: StubCompressor())
        }
    }

    /// A mandatory section larger than the budget throws instead of being dropped.
    @Test("regression: mandatory overflow throws")
    func mandatoryOverflowThrows() async {
        let sections = [makeSection(id: "req", priority: 100, tokens: 90, compression: .keep)]
        await #expect(throws: PromptCompressionError.self) {
            try await TokenBudget(maxTokens: 10).result(forResolvedSections: sections, compressor: StubCompressor())
        }
    }
}
