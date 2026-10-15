import Foundation
import MCP
import PKContracts
import PKTestSupport
import PositronicKit
import Testing
@testable import PKMCP

/// Records cancellation notifications the test server receives.
actor CancelledNotificationProbe {
    private(set) var wasCancelled = false

    func record() {
        wasCancelled = true
    }
}

@Suite("MCP workspace provider")
struct MCPWorkspaceProviderTests {
    private func streamableConfig(name: String, permission: MCPPermissionPolicy = .annotations) -> MCPServerConfiguration {
        MCPServerConfiguration(
            name: name,
            transport: .streamableHTTP(url: URL(string: "http://127.0.0.1:1/mcp")!, headers: [:]),
            permission: permission
        )
    }

    @Test("listTools maps server tools to custom workspace references")
    func listsTools() async throws {
        let server = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "echo")],
            callTool: { _, _ in CallTool.Result(content: [.text(text: "unused", annotations: nil, _meta: nil)]) }
        )
        defer { Task { await server.stop() } }

        let provider = try makeMCPProvider(
            config: streamableConfig(name: "tools"),
            clientTransport: server.clientTransport
        )
        let tools = try await provider.listTools()

        #expect(tools.count == 1)
        #expect(tools.first?.toolID == "echo")
        #expect(tools.first?.displayName == "echo")
    }

    @Test("executeTool forwards arguments and returns the mapped output")
    func executesTool() async throws {
        let recorder = MCPCallRecorder()
        let server = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "echo")],
            callTool: { name, arguments in
                await recorder.record(name: name, arguments: arguments)
                return CallTool.Result(content: [.text(text: "echo-output", annotations: nil, _meta: nil)])
            }
        )
        defer { Task { await server.stop() } }

        let provider = try makeMCPProvider(
            config: streamableConfig(name: "call"),
            clientTransport: server.clientTransport
        )
        let result = try await provider.executeTool(id: "echo", parameters: ["text": "hello"])

        #expect(result.isSuccess)
        #expect(result.output == "echo-output")
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.name == "echo")
        #expect(calls.first?.arguments?["text"]?.stringValue == "hello")
    }

    @Test("isError results become failed tool results")
    func errorResultsBecomeFailures() async throws {
        let server = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "broken")],
            callTool: { _, _ in
                CallTool.Result(
                    content: [.text(text: "server said no", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        )
        defer { Task { await server.stop() } }

        let provider = try makeMCPProvider(
            config: streamableConfig(name: "error"),
            clientTransport: server.clientTransport
        )
        let result = try await provider.executeTool(id: "broken", parameters: [:])

        #expect(!result.isSuccess)
        #expect(result.error?.contains("server said no") == true)
    }

    @Test("list_changed invalidates the cached tool list for the next capture")
    func listChangedInvalidatesCache() async throws {
        let server = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "first")],
            callTool: { _, _ in CallTool.Result(content: []) }
        )
        defer { Task { await server.stop() } }

        let provider = try makeMCPProvider(
            config: streamableConfig(name: "changed"),
            clientTransport: server.clientTransport
        )
        let initial = try await provider.listTools()
        #expect(initial.count == 1)

        await server.toolStore.append(readOnlyTool(name: "second"))
        try await server.server.notify(ToolListChangedNotification.message())

        let deadline = ContinuousClock.now + .seconds(5)
        var count = initial.count
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            count = try await provider.listTools().count
            if count == 2 { break }
        }
        #expect(count == 2)
    }

    @Test("cancelling a call sends a cancelled notification to the server")
    func cancellationSendsNotification() async throws {
        let probe = CancelledNotificationProbe()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "cancel-server",
            version: "1.0.0",
            capabilities: Server.Capabilities(tools: .init())
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [readOnlyTool(name: "slow")])
        }
        await server.withMethodHandler(CallTool.self) { _ in
            try await Task.sleep(for: .seconds(30))
            return CallTool.Result(content: [])
        }
        await server.onNotification(CancelledNotification.self) { _ in
            await probe.record()
        }
        try await server.start(transport: serverTransport)
        defer { Task { await server.stop() } }

        let provider = try makeMCPProvider(
            config: streamableConfig(name: "cancel"),
            clientTransport: clientTransport
        )
        _ = try await provider.listTools()

        let call = Task { try await provider.executeTool(id: "slow", parameters: [:]) }
        try await Task.sleep(for: .milliseconds(250))
        call.cancel()
        _ = try? await call.value

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await probe.wasCancelled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await probe.wasCancelled)
    }

    @Test("a call timeout fails the result and cancels the request")
    func callTimeoutFails() async throws {
        let server = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "slow")],
            callTool: { _, _ in
                try await Task.sleep(for: .seconds(30))
                return CallTool.Result(content: [])
            }
        )
        defer { Task { await server.stop() } }

        var config = streamableConfig(name: "timeout")
        config.callTimeout = .milliseconds(100)
        let provider = try makeMCPProvider(
            config: config,
            clientTransport: server.clientTransport
        )
        let result = try await provider.executeTool(id: "slow", parameters: [:])

        #expect(!result.isSuccess)
        #expect(result.error?.contains("timed out") == true)
    }

    @Test("the factory passes the workspace factory conformance suite")
    func factoryConformance() throws {
        let factory = MCPWorkspaceFactory(secretResolver: MCPDictionarySecretResolver([:]))
        let reference = try makeMCPWorkspaceReference(
            name: "conform",
            config: streamableConfig(name: "conform")
        )
        try WorkspaceFactoryConformanceSuite.run(
            factory: factory,
            supportedReference: reference
        )
    }

    @Test("unresolvable standard input server configuration reports a connection failure")
    func invalidExecutableFails() async throws {
        let config = MCPServerConfiguration(
            name: "missing",
            transport: .stdio(
                executable: "/definitely/not/an/executable",
                arguments: [],
                environment: [:]
            )
        )
        let reference = try makeMCPWorkspaceReference(name: "missing", config: config)
        let provider = MCPWorkspaceProvider(
            reference: reference,
            configuration: config,
            secretResolver: MCPDictionarySecretResolver([:]),
            transportFactory: nil
        )
        let result = try await provider.executeTool(id: "anything", parameters: [:])
        #expect(!result.isSuccess)
    }
}
