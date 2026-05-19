import Foundation
import Logging
import PKPrompt
import PKShared
@testable import PositronicKit
import Testing

private final class PromptAssemblyLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Logger.Level, String)] = []

    func append(_ level: Logger.Level, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((level, message))
    }

    func messages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.1)
    }
}

private struct PromptAssemblyTestLogHandler: LogHandler {
    let sink: PromptAssemblyLogSink
    var logLevel: Logger.Level = .debug
    var metadata = Logger.Metadata()

    subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata _: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        sink.append(level, message.description)
    }
}

@Suite("PromptAssembly")
struct PromptAssemblyTests {
    private func makeRequest(userQuery: String = "hello") -> LLMPromptRequest {
        LLMPromptRequest(userQuery: userQuery, chatHistory: [], tools: [], workspaces: [], primaryWorkspace: nil, requestOriginName: nil)
    }

    struct MockSection: Prompt, Sendable {
        let id: String
        let content: String

        init(id: String, content: String = "test content") {
            self.id = id
            self.content = content
        }

        var body: some Prompt {
            TextPrompt(content, id: id, priority: 10)
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
        let resolved = sections.flatMap { try! $0.assemblePrompt().sections }
        #expect(resolved.map(\.id) == ["s1", "s2", "s3"])
    }

    @Test("PromptBuilder composes sections")
    func builderComposesSections() {
        @PromptBuilder
        func build() -> some Prompt {
            MockSection(id: "s1")
            [MockSection(id: "s2"), MockSection(id: "s3")]
            if true {
                MockSection(id: "s4")
            }
        }

        let resolved = try! build().assemblePrompt().sections
        #expect(resolved.map(\.id) == ["s1", "s2", "s3", "s4"])
    }

    @Test("Prompt assembly pipeline executes stages")
    func pipelineExecutesStages() async throws {
        let context = PromptAssemblyContext(request: makeRequest())

        struct CustomStage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append(MockSection(id: "custom"))
            }
        }

        let pipeline = Pipeline<PromptAssemblyContext, PromptAssemblyEvent>(stages: [CustomStage()])
        let stream = pipeline.execute(context)
        for try await _ in stream {}

        let sections = await context.sections
        let resolved = sections.flatMap { try! $0.assemblePrompt().sections }
        #expect(resolved.count == 1)
        #expect(resolved.first?.id == "custom")
    }

    @Test("PromptAssembler assembles runtime requests with the default pipeline")
    func promptBuilderUsesPipeline() async throws {
        let prompt = try await PromptAssembler.assemble(makeRequest(userQuery: "pipeline test"))
        let resolved = prompt.sections

        #expect(resolved.contains { $0.id == "system" })
        #expect(resolved.contains { $0.id == "user_query" })
        #expect(resolved.first(where: { $0.id == "user_query" })?.content.text == "pipeline test")
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
            options: PromptAssemblyOptions(
                overridePipeline: Pipeline<PromptAssemblyContext, PromptAssemblyEvent>(stages: [CustomStage()])
            )
        )

        #expect(prompt.sections.map { $0.id } == ["override_assembly"])
    }

    @Test("PromptAssembler emits verbose assembly logs when requested")
    func promptAssemblerEmitsVerboseLogs() async throws {
        struct CustomStage: PromptAssemblyStage {
            func execute(_ context: PromptAssemblyContext) async throws {
                await context.append(PromptAssemblyTests.MockSection(id: "verbose_assembly"))
            }
        }

        let sink = PromptAssemblyLogSink()
        let logger = Logger(label: "test.prompt-assembly") { _ in
            PromptAssemblyTestLogHandler(sink: sink)
        }

        _ = try await PromptAssembler.assemble(
            makeRequest(userQuery: "test"),
            options: PromptAssemblyOptions(
                overridePipeline: Pipeline<PromptAssemblyContext, PromptAssemblyEvent>(stages: [CustomStage()]),
                logger: logger
            )
        )

        let messages = sink.messages()
        #expect(messages.contains("Starting pipeline stage: CustomStage"))
        #expect(messages.contains(where: { $0.hasPrefix("Completed pipeline stage: CustomStage in ") }))
        #expect(messages.contains("Resolved 1 prompt section(s) from 1 prompt fragment(s)."))
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

        await #expect(throws: AssembledPrompt.ValidationError.self) {
            _ = try await PromptAssembler.assemble(
                makeRequest(userQuery: "test"),
                options: PromptAssemblyOptions(
                    overridePipeline: Pipeline<PromptAssemblyContext, PromptAssemblyEvent>(stages: [DuplicateStage()])
                )
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
            options: PromptAssemblyOptions(
                overridePipeline: Pipeline<PromptAssemblyContext, PromptAssemblyEvent>(stages: [CustomStage()])
            )
        )

        #expect(prompt.sections.map { $0.id } == ["from_options"])
    }

    @Test("PromptAssembler returns a final rendered prompt artifact")
    func promptAssemblerReturnsRenderedPrompt() async throws {
        let rendered = try await PromptAssembler.assemble(makeRequest(userQuery: "final artifact"))

        #expect(rendered.sectionsByID["user_query"] == "final artifact")

        let messages = rendered.buildMessages()
        #expect(messages.count >= 1)
    }

    @Test("RenderedPrompt builds provider-neutral conversation messages")
    func renderedPromptBuildsConversationMessages() async throws {
        let rendered = try await PromptAssembler.assemble(makeRequest(userQuery: "final artifact"))

        let messages = rendered.buildConversationMessages()

        #expect(messages.count >= 1)
        #expect(messages.last?.role == .user)
        #expect(messages.last?.content == "final artifact")
    }

    @Test("RenderedPrompt projections stay aligned across message models")
    func renderedPromptProjectionsStayAligned() async throws {
        let rendered = RenderedPrompt(
            sections: [
                .init(
                    id: "system",
                    role: .system,
                    priority: 100,
                    estimatedTokens: 1,
                    compression: .keep,
                    type: .text,
                    cachePolicy: .stable,
                    path: ["prompt", "system"],
                    parentID: nil,
                    content: .text("System rules")
                ),
                .init(
                    id: "history",
                    role: .chatHistory,
                    priority: 50,
                    estimatedTokens: 1,
                    compression: .keep,
                    type: .list,
                    cachePolicy: .volatile,
                    path: ["prompt", "history"],
                    parentID: nil,
                    content: .messages([
                        Message(content: "Question", role: .user),
                        Message(
                            content: "Answer",
                            role: .assistant,
                            think: "Reasoning",
                            toolCalls: [ToolCall(name: "search", arguments: ["q": .string("x")])]
                        ),
                        Message(content: "Tool output", role: .tool),
                    ])
                ),
                .init(
                    id: "query",
                    role: .userQuery,
                    priority: 10,
                    estimatedTokens: 1,
                    compression: .keep,
                    type: .text,
                    cachePolicy: .volatile,
                    path: ["prompt", "query"],
                    parentID: nil,
                    content: .text("Latest question")
                ),
            ],
            string: "",
            sectionsByID: [
                "system": "System rules",
                "query": "Latest question",
            ]
        )

        let llmMessages = rendered.buildMessages()
        let uiMessages = rendered.buildConversationMessages()

        #expect(llmMessages.count == 5)
        #expect(uiMessages.count == 5)

        #expect(llmMessages.first?.role == LLMMessage.Role.system)
        #expect(llmMessages.first?.content == uiMessages.first?.content)

        #expect(llmMessages[1].role == LLMMessage.Role.user)
        #expect(llmMessages[1].content == uiMessages[1].content)

        #expect(llmMessages[2].role == LLMMessage.Role.assistant)
        #expect(llmMessages[2].content == "<think>Reasoning</think>\nAnswer")
        #expect(llmMessages[2].toolCalls?.first?.name == "search")
        #expect(uiMessages[2].content == "Answer")
        #expect(uiMessages[2].think == "Reasoning")

        #expect(llmMessages[3].role == LLMMessage.Role.user)
        #expect(llmMessages[3].content.contains("<tool_response>"))
        #expect(uiMessages[3].role == Message.MessageRole.tool)
        #expect(uiMessages[3].content == "Tool output")

        #expect(llmMessages[4].role == LLMMessage.Role.user)
        #expect(uiMessages[4].role == Message.MessageRole.user)
        #expect(llmMessages[4].content == uiMessages[4].content)
    }
}
