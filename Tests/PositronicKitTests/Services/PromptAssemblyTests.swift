import Foundation
import PKPrompt
import PKShared
import PositronicKit
import Testing

@Suite("PromptAssembly")
struct PromptAssemblyTests {
    private func makeRequest(userQuery: String = "hello") -> LLMPromptRequest {
        LLMPromptRequest(userQuery: userQuery, chatHistory: [], tools: [], workspaces: [], primaryWorkspace: nil, clientName: nil)
    }

    struct MockSection: PromptLeaf, Sendable {
        let id: String
        let priority: Int = 10
        let estimatedTokens: Int = 10
        let content: String

        init(id: String, content: String = "test content") {
            self.id = id
            self.content = content
        }

        func renderContent() async -> String? {
            content
        }
    }

    @Test("PromptAssemblyContext holds properties")
    func contextHoldsProperties() async {
        let request = makeRequest(userQuery: "custom query")
        let agent = AgentInstance(id: UUID(), name: "TestAgent", description: "desc", privateTimelineId: UUID())
        let timeline = Timeline(id: UUID(), title: "TestTimeline")
        let ext = [MockSection(id: "ext")]

        let context = PromptAssemblyContext(request: request, agentInstance: agent, timeline: timeline, extensionSections: ext)

        #expect(await context.request.userQuery == "custom query")
        #expect(await context.agentInstance?.name == "TestAgent")
        #expect(await context.timeline?.title == "TestTimeline")
        #expect(await context.extensionSections.count == 1)
    }

    @Test("PromptAssemblyContext appends sections")
    func contextAppendsSections() async {
        let context = PromptAssemblyContext(request: makeRequest())

        await context.append(MockSection(id: "s1"))
        await context.append([MockSection(id: "s2"), MockSection(id: "s3")])

        let sections = await context.sections
        let resolved = sections.flatMap { $0.resolve(in: PromptResolutionContext()) }
        #expect(resolved.map(\.id) == ["s1", "s2", "s3"])
    }

    @Test("PromptBuilder composes sections")
    func builderComposesSections() {
        @PromptBuilder
        func build() -> some PromptComposite {
            MockSection(id: "s1")
            [MockSection(id: "s2"), MockSection(id: "s3")]
            if true {
                MockSection(id: "s4")
            }
        }

        let resolved = build().resolve(in: PromptResolutionContext())
        #expect(resolved.map(\.id) == ["s1", "s2", "s3", "s4"])
    }

    @Test("PromptAssemblyPipeline executes stages")
    func pipelineExecutesStages() async throws {
        let context = PromptAssemblyContext(request: makeRequest())

        struct CustomStage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append(MockSection(id: "custom"))
            }
        }

        let pipeline = PromptAssemblyPipeline(stages: [CustomStage()])
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        let sections = await context.sections
        let resolved = sections.flatMap { $0.resolve(in: PromptResolutionContext()) }
        #expect(resolved.count == 1)
        #expect(resolved.first?.id == "custom")
    }

    @Test("PromptAssembler assembles runtime requests with the default pipeline")
    func promptBuilderUsesPipeline() async throws {
        let prompt = try await PromptAssembler.assemble(makeRequest(userQuery: "pipeline test"))
        let resolved = prompt.resolvedSections

        #expect(resolved.contains { $0.id == "system" })
        #expect(resolved.contains { $0.id == "user_query" })
        #expect(await resolved.first(where: { $0.id == "user_query" })?.render() == "pipeline test")
    }

    @Test("PromptAssembler uses override pipeline in assemble")
    func promptBuilderUsesOverridePipeline() async throws {
        struct CustomStage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append(PromptAssemblyTests.MockSection(id: "override_assembly"))
            }
        }

        let prompt = try await PromptAssembler.assemble(
            makeRequest(userQuery: "test"),
            options: PromptAssemblyOptions(overridePipeline: PromptAssemblyPipeline(stages: [CustomStage()]))
        )
        let resolved = prompt.resolvedSections

        #expect(resolved.count == 1)
        #expect(resolved.first?.id == "override_assembly")
    }

    @Test("PromptAssembler rejects duplicate section ids")
    func promptBuilderRejectsDuplicateSectionIDs() async {
        struct DuplicateStage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append([
                    PromptAssemblyTests.MockSection(id: "duplicate", content: "one"),
                    PromptAssemblyTests.MockSection(id: "duplicate", content: "two"),
                ])
            }
        }

        await #expect(throws: PromptSectionValidationError.self) {
            _ = try await PromptAssembler.assemble(
                makeRequest(userQuery: "test"),
                options: PromptAssemblyOptions(overridePipeline: PromptAssemblyPipeline(stages: [DuplicateStage()]))
            )
        }
    }

    @Test("PromptAssembler accepts advanced options object")
    func promptAssemblerUsesOptionsObject() async throws {
        struct CustomStage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append(PromptAssemblyTests.MockSection(id: "from_options"))
            }
        }

        let prompt = try await PromptAssembler.assemble(
            makeRequest(userQuery: "test"),
            options: PromptAssemblyOptions(overridePipeline: PromptAssemblyPipeline(stages: [CustomStage()]))
        )

        #expect(prompt.resolvedSections.map(\.id) == ["from_options"])
    }
}
