import Foundation
import PKContracts
import PKUtilities
import Testing
@testable import PositronicKit

private func makeCompressionSection(
    id: String,
    priority: Int,
    estimatedTokens: Int,
    compression: CompressionStrategy,
    cachePolicy: CachePolicy,
    text: @escaping @Sendable () async -> String
) -> PromptSection {
    PromptSection(
        id: id,
        role: .context,
        priority: priority,
        estimatedTokens: estimatedTokens,
        compression: compression,
        type: .text,
        cachePolicy: cachePolicy,
        path: ["prompt", "CompressionMockSection", "TextPrompt", cachePolicy.pathComponent, id],
        render: { _ in .text(await text()) }
    )
}

private struct IntegrationCompressor: SectionCompressor {
    let summary: String

    func summarize(_ text: String) async throws -> String { summary }
    func summarize(request: SummaryRequest) async throws -> String { summary }
}

private actor IntegrationCounter {
    private var calls = 0
    func increment() { calls += 1 }
    func value() -> Int { calls }
}

@Suite("Structured compression integration", .tags(.unit))
struct StructuredCompressionIntegrationTests {
    @Test("Changed subtree is prioritized under token pressure")
    func changedSubtreePrioritized() async throws {
        let request = LLMPromptRequest(userQuery: "test", chatHistory: [], tools: [], workspaces: [], primaryWorkspace: nil, requestOriginName: nil)

        let prompt = try await PromptAssembler.assemble(
            request,
            options: PromptAssemblyOptions(
                customSections: {
                    [
                        makeCompressionSection(id: "stable_node", priority: 10, estimatedTokens: 300, compression: .summarize, cachePolicy: .stable, text: { "stable text" }),
                        makeCompressionSection(id: "changed_node", priority: 1, estimatedTokens: 300, compression: .summarize, cachePolicy: .volatile, text: { "changed text" }),
                    ]
                },
                tokenBudget: TokenBudget(maxTokens: 180, reserveForResponse: 0),
                compressor: IntegrationCompressor(summary: "short"),
                structuredDiff: StructuredDiffHint(
                    changedNodePaths: [["prompt", "CompressionMockSection", "TextPrompt", "volatile", "changed_node"]],
                    stableNodePaths: [["prompt", "CompressionMockSection", "TextPrompt", "stable", "stable_node"]]
                )
            )
        )

        #expect(prompt.sections.map { $0.id } == ["changed_node"])
    }

    @Test("Shared executor re-summarizes repeated builds without a summary cache")
    func cachePreservedAcrossBuilds() async throws {
        struct CountingCompressor: SectionCompressor {
            let counter: IntegrationCounter
            func summarize(_ text: String) async throws -> String { await counter.increment(); return "cached-summary" }
            func summarize(request: SummaryRequest) async throws -> String { await counter.increment(); return "cached-summary" }
        }

        let request = LLMPromptRequest(userQuery: "test", chatHistory: [], tools: [], workspaces: [], primaryWorkspace: nil, requestOriginName: nil)
        let executor = StructuredCompressionExecutor()
        let counter = IntegrationCounter()
        let compressor = CountingCompressor(counter: counter)
        let budget = TokenBudget(maxTokens: 100, reserveForResponse: 0)

        let options = PromptAssemblyOptions(
            customSections: {
                [
                    makeCompressionSection(id: "cache_node", priority: 1, estimatedTokens: 300, compression: .summarize, cachePolicy: .volatile, text: { "cache me" }),
                ]
            },
            tokenBudget: budget,
            compressor: compressor,
            structuredExecutor: executor
        )

        _ = try await PromptAssembler.assemble(request, options: options)
        _ = try await PromptAssembler.assemble(request, options: options)

        #expect(await counter.value() == 2)
    }

    @Test("Default node metadata hash changes when section content changes")
    func nodeMetadataTracksContentChanges() async throws {
        actor ContentBox { // swiftlint:disable:this concurrency_reference_box_naming -- actor-based test double (see docs/Concurrency/exception-manifest.md)
            private var value: String
            init(_ value: String) { self.value = value }
            func set(_ value: String) { self.value = value }
            func get() -> String { value }
        }

        struct CountingCompressor: SectionCompressor {
            let counter: IntegrationCounter
            func summarize(_ text: String) async throws -> String { await counter.increment(); return "summary" }
            func summarize(request: SummaryRequest) async throws -> String { await counter.increment(); return "summary" }
        }

        let request = LLMPromptRequest(userQuery: "test", chatHistory: [], tools: [], workspaces: [], primaryWorkspace: nil, requestOriginName: nil)
        let content = ContentBox("version-1")
        let executor = StructuredCompressionExecutor()
        let counter = IntegrationCounter()
        let compressor = CountingCompressor(counter: counter)
        let budget = TokenBudget(maxTokens: 100, reserveForResponse: 0)

        let options = PromptAssemblyOptions(
            customSections: { [content] in
                [makeCompressionSection(id: "cache_node", priority: 1, estimatedTokens: 300, compression: .summarize, cachePolicy: .volatile, text: { await content.get() })]
            },
            tokenBudget: budget,
            compressor: compressor,
            structuredExecutor: executor
        )

        _ = try await PromptAssembler.assemble(request, options: options)
        await content.set("version-2")
        _ = try await PromptAssembler.assemble(request, options: options)

        #expect(await counter.value() == 2)
    }
}
