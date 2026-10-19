import Foundation
import MCP
import PKContracts
import PKTestSupport
import PositronicKit
import Testing
@testable import PKMCP

/// Records which tools the runtime's approval gate was asked about.
actor RecordingMCPApprovalPolicy: ToolApprovalPolicy {
    private(set) var requestedTools: [String] = []
    private let decision: ToolApprovalDecision

    init(decision: ToolApprovalDecision = .deny) {
        self.decision = decision
    }

    func requestApproval(tool: AnyTool, arguments _: [String: AnyCodable]) async -> ToolApprovalDecision {
        requestedTools.append(tool.callName)
        return decision
    }
}

// `.serialized`: these stories drive a scripted streaming model through wall-clock waits.
@Suite("MCP workspace stories", .serialized)
struct MCPWorkspaceStoryTests {
    @Test("a Turn reaches an MCP tool through call_tool with a durable intent and result")
    func turnCallsMCPTool() async throws {
        let recorder = MCPCallRecorder()
        let server = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "echo")],
            callTool: { name, arguments in
                await recorder.record(name: name, arguments: arguments)
                return CallTool.Result(
                    content: [.text(text: "echo:hello", annotations: nil, _meta: nil)]
                )
            }
        )
        defer { Task { await server.stop() } }

        let workspaceRoot = TestRuntime.uniqueWorkspaceRoot()
        let factory = MCPWorkspaceFactory(
            secretResolver: MCPDictionarySecretResolver([:]),
            fallback: MockWorkspaceCreator(),
            transportFactory: { _ in server.clientTransport }
        )
        let test = TestRuntime(
            workspaceRoot: workspaceRoot,
            runtime: .init(
                workspaceProfile: .hostManaged(root: workspaceRoot),
                workspaceCreator: factory
            )
        )

        let timeline = try await test.timelines.create(title: "MCP story")
        let agent = try await test.agents.create(name: "MCP Agent", description: "story")
        try await test.agents.attach(agent.id, to: timeline.id)

        let config = MCPServerConfiguration(
            name: "story",
            transport: .streamableHTTP(url: URL(string: "http://127.0.0.1:1/mcp")!, headers: [:])
        )
        let created = try await test.workspaces.createMCPWorkspace(config, for: timeline.id)
        let fetched = try await test.workspaces.get(created.id, includeTools: false)
        #expect(fetched?.metadata?[MCPServerConfiguration.metadataKey] != nil)

        test.llm.mockClient.nextToolCalls = [[
            MockToolCall(
                id: "call-1",
                name: "call_tool",
                arguments: #"{"tool":"echo","arguments":{"text":"hello"}}"#
            )
        ]]
        test.llm.mockClient.nextResponses = ["", "Echo complete"]

        let turn = try await test.timelines.open(timeline.id).startTurn("call echo")
        let events = await turn.events().collect()

        #expect(try await turn.outcome() == .completed)
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.name == "echo")
        #expect(calls.first?.arguments?["text"]?.stringValue == "hello")
        let requestTools = test.llm.mockClient.generationCaptureHistory.first?.tools ?? []
        let callTool = try #require(requestTools.first(where: { $0.name == "call_tool" }))
        let callToolSchema = callTool.parameters?.asDictionary ?? [:]
        let properties = callToolSchema["properties"]?.asDictionary ?? [:]
        let selector = properties["tool"]?.asDictionary ?? [:]
        #expect(selector["enum"]?.asArray?.compactMap(\.asString) == [
            "append_file", "delete_file", "echo", "edit_file", "list_files",
            "read_file", "search_files", "write_file",
        ])
        #expect(events.contains { event in
            if case let .completion(.toolExecution(id, status)) = event,
               case let .workspaceSucceeded(result, _, _) = status
            {
                return id == "call-1" && result.output == "echo:hello"
            }
            return false
        })
        #expect(events.contains { event in
            if case let .completion(.generationCompleted(message, _)) = event {
                return message.content == "Echo complete"
            }
            return false
        })

        // Durable tool intent and result audit.
        let intents = try await test.repository.fetchToolIntents(turnID: turn.id)
        let results = try await test.repository.fetchToolResults(turnID: turn.id)
        #expect(intents.count == 1)
        #expect(results.count == 1)
    }

    @Test("an MCP Workspace rejects identifiers outside the captured list")
    func rejectsUnlistedMCPTool() async throws {
        let recorder = MCPCallRecorder()
        let server = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "echo")],
            callTool: { name, arguments in
                await recorder.record(name: name, arguments: arguments)
                return CallTool.Result(content: [.text(text: "should not run", annotations: nil, _meta: nil)])
            }
        )
        defer { Task { await server.stop() } }

        let workspaceRoot = TestRuntime.uniqueWorkspaceRoot()
        let factory = MCPWorkspaceFactory(
            secretResolver: MCPDictionarySecretResolver([:]),
            fallback: MockWorkspaceCreator(),
            transportFactory: { _ in server.clientTransport }
        )
        let test = TestRuntime(
            workspaceRoot: workspaceRoot,
            runtime: .init(
                workspaceProfile: .hostManaged(root: workspaceRoot),
                workspaceCreator: factory
            )
        )
        let timeline = try await test.timelines.create(title: "MCP selector rejection")
        let agent = try await test.agents.create(name: "MCP Agent", description: "selector rejection")
        try await test.agents.attach(agent.id, to: timeline.id)
        let config = MCPServerConfiguration(
            name: "selector-rejection",
            transport: .streamableHTTP(url: URL(string: "http://127.0.0.1:1/mcp")!, headers: [:])
        )
        _ = try await test.workspaces.createMCPWorkspace(config, for: timeline.id)

        test.llm.mockClient.nextToolCalls = [[
            MockToolCall(
                id: "call-unlisted",
                name: "call_tool",
                arguments: #"{"tool":"not_listed","arguments":{}}"#
            )
        ]]
        test.llm.mockClient.nextResponses = ["", "Handled"]

        let turn = try await test.timelines.open(timeline.id).startTurn("call an unlisted tool")
        _ = await turn.events().collect()

        #expect(try await turn.outcome() == .completed)
        #expect(await recorder.calls.isEmpty)
        let results = try await test.repository.fetchToolResults(turnID: turn.id)
        #expect(results.count == 1)
        #expect(results.first?.isSuccessful == false)
    }

    @Test("the approval gate fires for a non-read-only MCP tool")
    func approvalGateFiresForMutatingTool() async throws {
        let recorder = MCPCallRecorder()
        let server = try await makeInMemoryMCPServer(
            tools: [mutatingTool(name: "write")],
            callTool: { name, arguments in
                await recorder.record(name: name, arguments: arguments)
                return CallTool.Result(content: [.text(text: "should not run", annotations: nil, _meta: nil)])
            }
        )
        defer { Task { await server.stop() } }

        let approval = RecordingMCPApprovalPolicy(decision: .deny)
        let workspaceRoot = TestRuntime.uniqueWorkspaceRoot()
        let factory = MCPWorkspaceFactory(
            secretResolver: MCPDictionarySecretResolver([:]),
            fallback: MockWorkspaceCreator(),
            transportFactory: { _ in server.clientTransport }
        )
        let test = TestRuntime(
            workspaceRoot: workspaceRoot,
            runtime: .init(
                workspaceProfile: .hostManaged(root: workspaceRoot),
                workspaceCreator: factory,
                toolApprovalPolicy: approval
            )
        )

        let timeline = try await test.timelines.create(title: "MCP approval")
        let agent = try await test.agents.create(name: "MCP Agent", description: "approval")
        try await test.agents.attach(agent.id, to: timeline.id)

        let config = MCPServerConfiguration(
            name: "approval",
            transport: .streamableHTTP(url: URL(string: "http://127.0.0.1:1/mcp")!, headers: [:]),
            permission: .always
        )
        _ = try await test.workspaces.createMCPWorkspace(config, for: timeline.id)

        test.llm.mockClient.nextToolCalls = [[
            MockToolCall(
                id: "call-approval",
                name: "call_tool",
                arguments: #"{"tool":"write","arguments":{}}"#
            )
        ]]
        test.llm.mockClient.nextResponses = ["", "Handled"]

        let turn = try await test.timelines.open(timeline.id).startTurn("call write")
        _ = await turn.events().collect()

        #expect(await approval.requestedTools.contains("write"))
        let calls = await recorder.calls
        #expect(calls.isEmpty, "a denied MCP tool must not reach the server")
    }

    @Test("one pooled profile serves many Timelines over one connection")
    func pooledProfileServesManyTimelines() async throws {
        let recorder = MCPCallRecorder()
        let server = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "echo")],
            callTool: { name, arguments in
                await recorder.record(name: name, arguments: arguments)
                return CallTool.Result(
                    content: [.text(text: "shared:hello", annotations: nil, _meta: nil)]
                )
            }
        )
        defer { Task { await server.stop() } }

        let counter = MCPTransportBuildCounter()
        let workspaceRoot = TestRuntime.uniqueWorkspaceRoot()
        let factory = MCPWorkspaceFactory(
            secretResolver: MCPDictionarySecretResolver([:]),
            profiles: [
                MCPServerProfile(
                    id: "shared",
                    configuration: MCPServerConfiguration(
                        name: "shared",
                        transport: .streamableHTTP(url: URL(string: "http://127.0.0.1:1/mcp")!, headers: [:])
                    ),
                    sessionScope: .pooled
                )
            ],
            fallback: MockWorkspaceCreator(),
            transportFactory: { _ in
                _ = await counter.increment()
                return server.clientTransport
            }
        )
        let test = TestRuntime(
            workspaceRoot: workspaceRoot,
            runtime: .init(
                workspaceProfile: .hostManaged(root: workspaceRoot),
                workspaceCreator: factory
            )
        )

        let profile = MCPServerProfile(
            id: "shared",
            configuration: MCPServerConfiguration(
                name: "shared",
                transport: .streamableHTTP(url: URL(string: "http://127.0.0.1:1/mcp")!, headers: [:])
            ),
            sessionScope: .pooled
        )
        let agent = try await test.agents.create(name: "Shared MCP Agent", description: "story")

        for index in 1...2 {
            let timeline = try await test.timelines.create(title: "MCP shared \(index)")
            try await test.agents.attach(agent.id, to: timeline.id)
            _ = try await test.workspaces.createMCPWorkspace(profile, for: timeline.id)

            test.llm.mockClient.nextToolCalls = [[
                MockToolCall(
                    id: "call-\(index)",
                    name: "call_tool",
                    arguments: #"{"tool":"echo","arguments":{"text":"hello"}}"#
                )
            ]]
            test.llm.mockClient.nextResponses = ["", "Done \(index)"]

            let turn = try await test.timelines.open(timeline.id).startTurn("call echo")
            _ = await turn.events().collect()
            #expect(try await turn.outcome() == .completed)
        }

        let calls = await recorder.calls
        #expect(calls.count == 2)
        #expect(await counter.count == 1, "both Timelines share one pooled connection")
    }
}
