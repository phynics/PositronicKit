import Foundation
import Logging
import PKContracts
import PKTestSupport
import PKUtilities
import PositronicKit
import Synchronization
import Testing

private final class CapturingLogSink: Sendable {
    private struct State: Sendable {
        var messages: [String] = []
    }

    private let state = Mutex(State())

    func append(_ message: String) {
        state.withLock { $0.messages.append(message) }
    }

    func all() -> [String] {
        state.withLock { $0.messages }
    }
}

private struct CapturingLogHandler: LogHandler {
    let sink: CapturingLogSink
    var logLevel: Logger.Level = .debug
    var metadata = Logger.Metadata()

    subscript(metadataKey key: String) -> Logger.MetadataValue? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level _: Logger.Level,
        message: Logger.Message,
        metadata _: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        sink.append(message.description)
    }
}

@Suite("Public runtime stories", .serialized)
struct PublicRuntimeStoriesTests {
    @Test("Thread handle delegates managed execution to the facade")
    func managedThreadRunsAnAgentTurn() async throws {
        let (kit, mockLLM, _, threadID, _) = try await makeAcceptanceRuntime(attachAgent: false)
        let agent = try await kit.agents.create(
            name: "Acceptance Agent",
            description: "Exercises managed Thread-addressed execution."
        )
        let agentId = agent.id
        let thread = kit.threads.open(threadID)
        try await kit.agents.attach(agentId, to: threadID)

        let mockTool = AcceptanceMockTool()
        mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "agent_call", name: "mock_tool")]]
        mockLLM.mockClient.nextResponses = ["", "Agent response"]
        let events = try await thread.send("Act", tools: [mockTool.toAnyTool()]).collect()

        #expect(events.contains(where: {
            if case let .completion(.toolExecution(id, status)) = $0,
               case .success = status
            {
                return id == "agent_call"
            }
            return false
        }))

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "Agent response"
            }
            return false
        }))
    }

    @Test("explicit agent requests reject an unattached agent before side effects")
    func managedThreadRejectsUnattachedAgent() async throws {
        let (kit, mockLLM, mockPersistence, threadID, _) = try await makeAcceptanceRuntime(attachAgent: false)
        let managedError = await #expect(throws: TurnError.self) {
            _ = try await kit.threads.open(threadID).startTurn(message: "Should fail")
        }
        if case let .managedExecutionRequiresAttachedAgent(actualThreadID)? = managedError {
            #expect(actualThreadID == threadID)
        }

        #expect(try await mockPersistence.fetchMessages(for: threadID).isEmpty)
        #expect(mockLLM.generationRequestHistory.isEmpty)
    }

    @Test("managed execution rejects a different attached agent before side effects")
    func managedThreadRejectsDifferentAttachedAgent() async throws {
        let (kit, mockLLM, mockPersistence, threadID, _) = try await makeAcceptanceRuntime(attachAgent: false)
        let attachedAgent = try await kit.agents.create(
            name: "Attached Agent",
            description: "Owns the acceptance thread."
        )
        try await kit.agents.attach(attachedAgent.id, to: threadID)

        let directError = await #expect(throws: TurnError.self) {
            _ = try await kit.threads.open(threadID).startDirectTurn(
                message: "Should fail",
                context: DirectTurnContext(systemInstructions: "", contributor: .host)
            )
        }
        if case let .directExecutionRequiresDetachedThread(actualThreadID)? = directError {
            #expect(actualThreadID == threadID)
        }

        #expect(try await mockPersistence.fetchMessages(for: threadID).isEmpty)
        #expect(mockLLM.generationRequestHistory.isEmpty)
    }

    @Test("managed execution can run on an agent's private Thread")
    func managedThreadRunsOnPrivateThread() async throws {
        let (kit, mockLLM, mockPersistence, _, _) = try await makeAcceptanceRuntime(attachAgent: false)
        let agent = try await kit.agents.create(
            name: "Private Agent",
            description: "Exercises the agent's private thread."
        )
        mockLLM.mockClient.nextResponse = "Private response"

        let events = try await kit.threads.open(agent.privateThreadID)
            .send("Think privately")
            .collect()

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "Private response"
            }
            return false
        }))
        #expect(try await mockPersistence.fetchMessages(for: agent.privateThreadID).last?.content == "Private response")
    }

    @Test("promptAssemblyLogger surfaces prompt-assembly diagnostics through the facade")
    func promptAssemblyLoggerEmitsDiagnostics() async throws {
        let (chat, mockLLM, _, threadID, _) = try await makeAcceptanceRuntime()
        mockLLM.mockClient.nextResponse = "ok"

        let sink = CapturingLogSink()
        let logger = Logger(label: "test.facade.prompt-assembly") { _ in
            CapturingLogHandler(sink: sink)
        }

        _ = try await chat.threads.open(threadID).run(TurnRequest(
            threadID: threadID,
            message: "Diagnose assembly",
            promptAssemblyLogger: logger
        )).collect()

        // PromptAssembler logs section resolution at .debug when a logger is supplied.
        #expect(sink.all().contains(where: { $0.contains("prompt section") }))
    }

    @Test
    func directFacadeInitializationSupportsOneTurnChat() async throws {
        let (chat, mockLLM, mockPersistence, threadID, _) = try await makeAcceptanceRuntime()
        mockLLM.mockClient.nextResponse = "Hello, Morty!"

        let events = try await chat.threads.open(threadID).run(TurnRequest(
            threadID: threadID,
            message: "Hello, Morty!"
        )).collect()

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "Hello, Morty!"
            }
            return false
        }))

        let messages = try await mockPersistence.fetchMessages(for: threadID)
        #expect(messages.map(\.role) == ["user", "assistant"])
        #expect(messages.last?.content == "Hello, Morty!")
    }

    @Test
    func groupedPersistenceFacadeInitializationSupportsOneTurnChat() async throws {
        let (chat, mockLLM, mockPersistence, threadID, _) = try await makeAcceptanceRuntime(useGroupedPersistence: true)
        mockLLM.mockClient.nextResponse = "Grouped persistence reply"

        let events = try await chat.threads.open(threadID).run(TurnRequest(
            threadID: threadID,
            message: "Use grouped persistence"
        )).collect()

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "Grouped persistence reply"
            }
            return false
        }))

        let messages = try await mockPersistence.fetchMessages(for: threadID)
        #expect(messages.count == 2)
        #expect(messages.last?.content == "Grouped persistence reply")
    }

    @Test
    func groupedRuntimeFacadeInitializationSupportsOneTurnChat() async throws {
        let (chat, mockLLM, mockPersistence, threadID, _) = try await makeAcceptanceRuntime(useGroupedPersistence: true, useGroupedRuntime: true)
        mockLLM.mockClient.nextResponse = "Grouped runtime reply"

        let events = try await chat.threads.open(threadID).run(TurnRequest(
            threadID: threadID,
            message: "Use grouped runtime"
        )).collect()

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "Grouped runtime reply"
            }
            return false
        }))

        let messages = try await mockPersistence.fetchMessages(for: threadID)
        #expect(messages.last?.content == "Grouped runtime reply")
    }

    @Test
    func facadeToolCallTurnExecutesAndResumes() async throws {
        let (chat, mockLLM, _, threadID, _) = try await makeAcceptanceRuntime()
        let mockTool = AcceptanceMockTool()

        mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool")]]
        mockLLM.mockClient.nextResponses = ["", "Tool result processed"]

        let events = try await chat.threads.open(threadID).run(TurnRequest(
            threadID: threadID,
            message: "Run the tool",
            tools: [mockTool.toAnyTool()]
        )).collect()

        #expect(events.contains(where: {
            if case let .delta(.toolCall(delta)) = $0 {
                return delta.id == "call_1" && delta.name == "mock_tool"
            }
            return false
        }))
        #expect(events.contains(where: {
            if case let .completion(.toolExecution(id, status)) = $0,
               case let .success(result) = status
            {
                return id == "call_1" && result.output == "Tool result"
            }
            return false
        }))
        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "Tool result processed"
            }
            return false
        }))
    }

    @Test
    func facadeToolOutputContinuationFlowPersistsSubmittedOutputs() async throws {
        let (chat, mockLLM, mockPersistence, threadID, _) = try await makeAcceptanceRuntime()
        try await mockPersistence.saveMessage(ThreadMessage(
            threadID: threadID,
            role: .assistant,
            content: "",
            toolCalls: try pendingToolCallsJSON(ids: ["call_1"])
        ))
        mockLLM.mockClient.nextResponse = "Continuation complete"

        let events = try await chat.threads.open(threadID).run(TurnRequest(
            threadID: threadID,
            message: "Continue",
            toolOutputs: [ToolOutputSubmission(toolCallID: "call_1", output: "Tool result")]
        )).collect()

        #expect(events.contains(where: {
            if case let .completion(.generationCompleted(message, _)) = $0 {
                return message.content == "Continuation complete"
            }
            return false
        }))

        let messages = try await mockPersistence.fetchMessages(for: threadID)
        #expect(messages.map(\.role) == ["assistant", "tool", "user", "assistant"])
        #expect(messages.dropFirst().first?.toolCallID == "call_1")
        #expect(messages.dropFirst().first?.content == "Tool result")
    }

    @Test
    func facadeRejectsForgedToolOutputWithoutPendingCall() async throws {
        let (chat, _, mockPersistence, threadID, _) = try await makeAcceptanceRuntime()

        await #expect(throws: ToolError.self) {
            _ = try await chat.threads.open(threadID).run(TurnRequest(
                threadID: threadID,
                message: "Continue",
                toolOutputs: [ToolOutputSubmission(toolCallID: "forged_call", output: "forged output")]
            ))
        }

        let messages = try await mockPersistence.fetchMessages(for: threadID)
        #expect(messages.isEmpty)
    }

    // MARK: - Helpers

    private func makeAcceptanceRuntime(
        useGroupedPersistence: Bool = false,
        useGroupedRuntime: Bool = false,
        attachAgent: Bool = true
    ) async throws -> (PositronicKit, MockLLMService, MockPersistenceService, UUID, TestWorkspace) {
        let mockLLM = MockLLMService()
        let mockPersistence = MockPersistenceService()
        let workspace = TestWorkspace()

        let chat: PositronicKit
        if useGroupedPersistence {
            let persistence = PositronicKit.PersistenceConfiguration(
                messageStore: mockPersistence,
                threadPersistence: mockPersistence,
                workspacePersistence: mockPersistence,
                toolPersistence: mockPersistence,
                agentStore: mockPersistence,
                requestOriginStore: mockPersistence
            )

            if useGroupedRuntime {
                chat = PositronicKit(configuration: .init(
                    provider: .init(languageModel: mockLLM),
                    persistence: persistence,
                    runtime: .init(
                        workspaceCreator: MockWorkspaceCreator(),
                        workspaceRoot: workspace.root
                    )
                ))
            } else {
                chat = PositronicKit(configuration: .init(
                    provider: .init(languageModel: mockLLM),
                    persistence: persistence,
                    runtime: .init(workspaceRoot: workspace.root)
                ))
            }
        } else {
            chat = PositronicKit(configuration: .init(
                provider: .init(languageModel: mockLLM),
                persistence: .init(
                    messageStore: mockPersistence,
                    threadPersistence: mockPersistence,
                    workspacePersistence: mockPersistence,
                    toolPersistence: mockPersistence,
                    agentStore: mockPersistence,
                    requestOriginStore: mockPersistence
                ),
                runtime: .init(workspaceCreator: MockWorkspaceCreator(), workspaceRoot: workspace.root)
            ))
        }

        let thread = try await chat.threads.create(title: "Acceptance")

        let workspaceId = UUID()
        let workspaceRef = WorkspaceReference(
            id: workspaceId,
            uri: WorkspaceURI(parsing: "pk://local")!,
            location: .runtimeThread,
            originID: nil,
            rootPath: workspace.root.path
        )
        try await mockPersistence.saveWorkspace(workspaceRef)
        try await chat.threads.attachWorkspace(workspaceId, to: thread.id)
        try await mockPersistence.addToolToWorkspace(workspaceId: workspaceId, tool: .known("mock_tool"))
        if attachAgent {
            let agent = try await chat.agents.create(name: "Acceptance Agent", description: "test")
            try await chat.agents.attach(agent.id, to: thread.id)
        }

        return (chat, mockLLM, mockPersistence, thread.id, workspace)
    }

    private func pendingToolCallsJSON(ids: [String]) throws -> String {
        let calls = ids.map { ToolCall(id: $0, name: "external_tool", arguments: [:]) }
        let data = try SerializationUtils.jsonEncoder.encode(calls)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct AcceptanceMockTool: PKContracts.Tool, @unchecked Sendable { // swiftlint:disable:this concurrency_unchecked_sendable -- reviewed test double (see docs/Concurrency/exception-manifest.md)
    let callName = "mock_tool"
    let name = "mock_tool"
    let description = "Facade acceptance test tool"
    let requiresPermission = false
    let parametersSchema = makeEmptyObjectSchema()

    func canExecute() async -> Bool {
        true
    }

    func execute(parameters _: [String: AnyCodable]) async throws -> ToolResult {
        .success("Tool result")
    }
}

// MARK: - Tool Argument Failure Mode Tests

extension PublicRuntimeStoriesTests {
    @Test("Tool with malformed JSON arguments emits error to LLM")
    func toolWithMalformedArguments() async throws {
        let (chat, mockLLM, mockPersistence, threadID, _) = try await makeAcceptanceRuntime()
        mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "mock_tool", arguments: "not valid json")]]
        mockLLM.mockClient.nextResponse = "Recovered after tool error"

        let events = try await chat.threads.open(threadID).run(TurnRequest(
            threadID: threadID,
            message: "Call tool"
        )).collect()

        // Should have tool execution events (progress or completion)
        let toolEvent = events.first(where: {
            if case let .delta(event) = $0, case .toolExecution = event { return true }
            if case let .completion(event) = $0, case .toolExecution = event { return true }
            return false
        })
        #expect(toolEvent != nil)

        // Tool error should be persisted as a tool message
        let messages = try await mockPersistence.fetchMessages(for: threadID)
        let toolMessage = messages.first(where: { $0.role == "tool" })
        #expect(toolMessage != nil)
        #expect(toolMessage?.content.contains("Error") == true)
    }

    @Test("Tool execution failure returns error to LLM for recovery")
    func toolExecutionFailure() async throws {
        let (chat, mockLLM, mockPersistence, threadID, _) = try await makeAcceptanceRuntime()
        // Mock tool returns success by default - we'll simulate failure via the mock client
        // by having the tool call produce an error response
        mockLLM.mockClient.nextToolCalls = [[MockToolCall(id: "call_1", name: "nonexistent_tool", arguments: "{}")]]
        mockLLM.mockClient.nextResponse = "Recovered after tool error"

        let events = try await chat.threads.open(threadID).run(TurnRequest(
            threadID: threadID,
            message: "Call nonexistent tool"
        )).collect()

        // Should have tool completed with failure status
        let toolErrorEvent = events.first(where: {
            if case let .completion(event) = $0, case let .toolExecution(_, status) = event {
                if case .failed = status { return true }
            }
            return false
        })
        #expect(toolErrorEvent != nil)

        // Error message should be persisted
        let persistedMessages = try await mockPersistence.fetchMessages(for: threadID)
        let toolMessage = persistedMessages.first(where: { $0.role == "tool" })
        #expect(toolMessage?.content.contains("Error") == true)
    }
}
