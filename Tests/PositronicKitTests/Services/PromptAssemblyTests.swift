import Foundation
import PositronicKit
import PKPrompt
import PKShared
import Testing

@Suite("PromptAssembly")
struct PromptAssemblyTests {

    // MARK: - Helpers

    private func makeRequest(userQuery: String = "hello") -> LLMPromptRequest {
        LLMPromptRequest(
            userQuery: userQuery,
            chatHistory: [],
            tools: [],
            workspaces: [],
            primaryWorkspace: nil,
            clientName: nil
        )
    }

    // MARK: - Mock Section

    struct MockSection: ContextSection, Sendable {
        let id: String
        let priority: Int = 10
        let estimatedTokens: Int = 10
        let content: String

        init(id: String, content: String = "test content") {
            self.id = id
            self.content = content
        }

        func render() async -> String? {
            content
        }
    }

    // MARK: - PromptAssemblyContext Tests

    @Test("PromptAssemblyContext holds properties")
    func contextHoldsProperties() async {
        let request = makeRequest(userQuery: "custom query")
        let agent = AgentInstance(id: UUID(), name: "TestAgent", description: "desc", privateTimelineId: UUID())
        let timeline = Timeline(id: UUID(), title: "TestTimeline")
        let ext = [MockSection(id: "ext")]

        let context = PromptAssemblyContext(
            request: request,
            agentInstance: agent,
            timeline: timeline,
            extensionSections: ext
        )

        #expect(await context.request.userQuery == "custom query")
        #expect(await context.agentInstance?.name == "TestAgent")
        #expect(await context.timeline?.title == "TestTimeline")
        #expect(await context.extensionSections.count == 1)
    }

    @Test("PromptAssemblyContext appends sections")
    func contextAppendsSections() async {
        let request = makeRequest()
        let context = PromptAssemblyContext(request: request)

        await context.append(MockSection(id: "s1"))
        await context.append([MockSection(id: "s2"), MockSection(id: "s3")])

        let sections = await context.sections
        #expect(sections.count == 3)
        #expect(sections[0].id == "s1")
        #expect(sections[1].id == "s2")
        #expect(sections[2].id == "s3")
    }

    // MARK: - ContextBuilder Tests

    @Test("ContextBuilder composes sections")
    func builderComposesSections() {
        @ContextBuilder
        func build() -> [ContextSection] {
            MockSection(id: "s1")
            [MockSection(id: "s2"), MockSection(id: "s3")]
            if true {
                MockSection(id: "s4")
            }
        }

        let sections = build()
        #expect(sections.count == 4)
        #expect(sections.map { $0.id } == ["s1", "s2", "s3", "s4"])
    }

    // MARK: - Pipeline Tests

    @Test("PromptAssemblyPipeline executes stages")
    func pipelineExecutesStages() async throws {
        let request = makeRequest()
        let context = PromptAssemblyContext(request: request)
        
        // Define a custom stage
        struct CustomStage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append(MockSection(id: "custom"))
            }
        }
        
        let pipeline = PromptAssemblyPipeline(stages: [CustomStage()])
        let stream = pipeline.execute(context)
        
        for try await _ in stream {}
        
        let sections = await context.sections
        #expect(sections.count == 1)
        #expect(sections.first?.id == "custom")
    }

    @Test("PromptBuilder uses pipeline for default assembly")
    func promptBuilderUsesPipeline() async throws {
        let request = makeRequest(userQuery: "pipeline test")
        let prompt = try await PromptBuilder.buildContext(request)
        
        // Check if some of the default sections are present
        let sections = await prompt.sections
        #expect(sections.contains { $0.id == "system" })
        #expect(sections.contains { $0.id == "user_query" })
        
        if let querySection = sections.first(where: { $0.id == "user_query" }) as? UserQuery {
            let content = await querySection.render()
            #expect(content == "pipeline test")
        }
    }

    @Test("PromptBuilder uses override pipeline in buildContext")
    func promptBuilder_usesOverridePipeline() async throws {
        struct CustomStage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append(PromptAssemblyTests.MockSection(id: "override_assembly"))
            }
        }
        
        let overridePipeline = PromptAssemblyPipeline(stages: [CustomStage()])
        let request = makeRequest(userQuery: "test")
        let prompt = try await PromptBuilder.buildContext(request, overridePipeline: overridePipeline)

        let sections = await prompt.sections
        #expect(sections.count == 1)
        #expect(sections.first?.id == "override_assembly")
    }

    @Test("PromptBuilder rejects duplicate section ids")
    func promptBuilder_rejectsDuplicateSectionIDs() async {
        struct DuplicateStage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append([
                    PromptAssemblyTests.MockSection(id: "duplicate", content: "one"),
                    PromptAssemblyTests.MockSection(id: "duplicate", content: "two"),
                ])
            }
        }

        let request = makeRequest(userQuery: "test")
        let pipeline = PromptAssemblyPipeline(stages: [DuplicateStage()])

        await #expect(throws: PromptSectionValidationError.self) {
            _ = try await PromptBuilder.buildContext(request, overridePipeline: pipeline)
        }
    }
}
