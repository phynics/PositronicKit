import Foundation
import PKPrompt
import Testing
@testable import PositronicKit

private struct CompressionMockSection: PromptLeaf, Sendable {
    let id: String
    let priority: Int
    let estimatedTokens: Int
    let compression: CompressionStrategy
    let cachePolicy: CachePolicy
    let text: String

    func renderContent() async -> String? {
        text
    }
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

@Suite("Structured compression integration")
struct StructuredCompressionIntegrationTests {
    @Test("Changed subtree is prioritized under token pressure")
    func changedSubtreePrioritized() async throws {
        struct Stage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append([
                    CompressionMockSection(id: "stable_node", priority: 10, estimatedTokens: 300, compression: .summarize, cachePolicy: .stable, text: "stable text"),
                    CompressionMockSection(id: "changed_node", priority: 1, estimatedTokens: 300, compression: .summarize, cachePolicy: .volatile, text: "changed text"),
                ])
            }
        }

        let request = LLMPromptRequest(userQuery: "test", chatHistory: [], tools: [], workspaces: [], primaryWorkspace: nil, clientName: nil)

        let prompt = try await PromptBuilder.buildContext(
            request,
            overridePipeline: PromptAssemblyPipeline(stages: [Stage()]),
            tokenBudget: TokenBudget(maxTokens: 180, reserveForResponse: 0),
            compressor: IntegrationCompressor(summary: "short"),
            structuredDiff: StructuredDiffHint(
                changedNodePaths: [["prompt", "volatile", "changed_node"]],
                stableNodePaths: [["prompt", "stable", "stable_node"]]
            )
        )

        let resolved = await prompt.resolveSections()
        #expect(resolved.count == 1)
        #expect(resolved.first?.id == "changed_node")
    }

    @Test("Shared executor preserves summary cache across builds")
    func cachePreservedAcrossBuilds() async throws {
        struct Stage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append([
                    CompressionMockSection(id: "cache_node", priority: 1, estimatedTokens: 300, compression: .summarize, cachePolicy: .volatile, text: "cache me"),
                ])
            }
        }

        struct CountingCompressor: SectionCompressor {
            let counter: IntegrationCounter
            func summarize(_ text: String) async throws -> String { await counter.increment(); return "cached-summary" }
            func summarize(request: SummaryRequest) async throws -> String { await counter.increment(); return "cached-summary" }
        }

        let request = LLMPromptRequest(userQuery: "test", chatHistory: [], tools: [], workspaces: [], primaryWorkspace: nil, clientName: nil)
        let executor = StructuredCompressionExecutor()
        let counter = IntegrationCounter()
        let compressor = CountingCompressor(counter: counter)
        let budget = TokenBudget(maxTokens: 100, reserveForResponse: 0)

        _ = try await PromptBuilder.buildContext(request, overridePipeline: PromptAssemblyPipeline(stages: [Stage()]), tokenBudget: budget, compressor: compressor, structuredDiff: nil, structuredExecutor: executor)
        _ = try await PromptBuilder.buildContext(request, overridePipeline: PromptAssemblyPipeline(stages: [Stage()]), tokenBudget: budget, compressor: compressor, structuredDiff: nil, structuredExecutor: executor)

        #expect(await counter.value() == 1)
    }

    @Test("Default node metadata hash changes when section content changes")
    func nodeMetadataTracksContentChanges() async throws {
        actor ContentBox {
            private var value: String
            init(_ value: String) { self.value = value }
            func set(_ value: String) { self.value = value }
            func get() -> String { value }
        }

        struct Stage: PromptAssemblyStage {
            let content: ContentBox
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append([
                    CompressionMockSection(id: "cache_node", priority: 1, estimatedTokens: 300, compression: .summarize, cachePolicy: .volatile, text: await content.get()),
                ])
            }
        }

        struct CountingCompressor: SectionCompressor {
            let counter: IntegrationCounter
            func summarize(_ text: String) async throws -> String { await counter.increment(); return "summary" }
            func summarize(request: SummaryRequest) async throws -> String { await counter.increment(); return "summary" }
        }

        let request = LLMPromptRequest(userQuery: "test", chatHistory: [], tools: [], workspaces: [], primaryWorkspace: nil, clientName: nil)
        let content = ContentBox("version-1")
        let executor = StructuredCompressionExecutor()
        let counter = IntegrationCounter()
        let compressor = CountingCompressor(counter: counter)
        let budget = TokenBudget(maxTokens: 100, reserveForResponse: 0)

        _ = try await PromptBuilder.buildContext(request, overridePipeline: PromptAssemblyPipeline(stages: [Stage(content: content)]), tokenBudget: budget, compressor: compressor, structuredDiff: nil, structuredExecutor: executor)
        await content.set("version-2")
        _ = try await PromptBuilder.buildContext(request, overridePipeline: PromptAssemblyPipeline(stages: [Stage(content: content)]), tokenBudget: budget, compressor: compressor, structuredDiff: nil, structuredExecutor: executor)

        #expect(await counter.value() == 2)
    }
}
