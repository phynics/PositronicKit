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

    @Test("Custom sections closure produces expected sections")
    func customSectionsProducesExpectedSections() async throws {
        let prompt = try await PromptAssembler.assemble(
            makeRequest(userQuery: "test"),
            options: PromptAssemblyOptions(
                customSections: { [MockSection(id: "custom")] }
            )
        )

        #expect(prompt.sections.map { $0.id } == ["custom"])
    }

    @Test("PromptAssembler assembles runtime requests with the default pipeline")
    func promptBuilderUsesPipeline() async throws {
        let prompt = try await PromptAssembler.assemble(makeRequest(userQuery: "pipeline test"))
        let resolved = prompt.sections

        #expect(resolved.contains { $0.id == "system" })
        #expect(resolved.contains { $0.id == "user_query" })
        #expect(resolved.first(where: { $0.id == "user_query" })?.content.text == "pipeline test")
    }

    @Test("Custom sections replace the default build")
    func customSectionsReplacesDefaultBuild() async throws {
        let prompt = try await PromptAssembler.assemble(
            makeRequest(userQuery: "test"),
            options: PromptAssemblyOptions(
                customSections: { [MockSection(id: "override_assembly")] }
            )
        )

        #expect(prompt.sections.map { $0.id } == ["override_assembly"])
    }

    @Test("PromptAssembler emits per-section assembly logs on the default build")
    func promptAssemblerEmitsVerboseLogs() async throws {
        let sink = PromptAssemblyLogSink()
        let logger = Logger(label: "test.prompt-assembly") { _ in
            PromptAssemblyTestLogHandler(sink: sink)
        }

        _ = try await PromptAssembler.assemble(
            makeRequest(userQuery: "test"),
            options: PromptAssemblyOptions(
                logger: logger
            )
        )

        let messages = sink.messages()
        #expect(messages.contains("Starting prompt section: SystemInstructions"))
        #expect(messages.contains(where: { $0.hasPrefix("Completed prompt section: SystemInstructions in ") }))
        #expect(messages.contains(where: { $0.contains("prompt section(s) from 7 prompt fragment(s).") }))
    }

    @Test("PromptAssembler rejects duplicate section ids")
    func promptBuilderRejectsDuplicateSectionIDs() async {
        await #expect(throws: AssembledPrompt.ValidationError.self) {
            _ = try await PromptAssembler.assemble(
                makeRequest(userQuery: "test"),
                options: PromptAssemblyOptions(
                    customSections: {
                        [MockSection(id: "duplicate", content: "one"), MockSection(id: "duplicate", content: "two")]
                    }
                )
            )
        }
    }

    @Test("PromptAssembler accepts advanced options object")
    func promptAssemblerUsesOptionsObject() async throws {
        let prompt = try await PromptAssembler.assemble(
            makeRequest(userQuery: "test"),
            options: PromptAssemblyOptions(
                customSections: { [MockSection(id: "from_options")] }
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
