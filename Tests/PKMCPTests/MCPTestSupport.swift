import Foundation
import MCP
import PKContracts
import PositronicKit
@testable import PKMCP

/// A configurable in-memory MCP server plus its paired client transport.
struct InMemoryMCPServer {
    let clientTransport: InMemoryTransport
    let server: Server
    let toolStore: MCPToolListStore

    func stop() async {
        await server.stop()
    }
}

/// A mutable tool list the server's `tools/list` handler reads.
actor MCPToolListStore {
    private(set) var tools: [Tool]

    init(tools: [Tool]) {
        self.tools = tools
    }

    func replace(with tools: [Tool]) {
        self.tools = tools
    }

    func append(_ tool: Tool) {
        tools.append(tool)
    }
}

/// Records `tools/call` invocations from the test server.
actor MCPCallRecorder {
    private(set) var calls: [(name: String, arguments: [String: MCP.Value]?)] = []

    func record(name: String, arguments: [String: MCP.Value]?) {
        calls.append((name, arguments))
    }
}

/// Builds a workspace reference whose metadata carries `config`, the way
/// ``WorkspaceCapability/createMCPWorkspace(_:for:)`` persists it.
func makeMCPWorkspaceReference(
    name: String,
    config: MCPServerConfiguration,
    location: WorkspaceReference.WorkspaceLocation = .runtime
) throws -> WorkspaceReference {
    WorkspaceReference(
        uri: WorkspaceURI(host: "mcp", path: name),
        location: location,
        metadata: [
            MCPServerConfiguration.metadataKey: .dictionary(try config.persistedMetadata())
        ]
    )
}

/// Starts an in-memory MCP server exposing a dynamically mutable tool list.
func makeInMemoryMCPServer(
    tools: [Tool],
    callTool: @escaping @Sendable (String, [String: MCP.Value]?) async throws -> CallTool.Result
) async throws -> InMemoryMCPServer {
    let toolStore = MCPToolListStore(tools: tools)
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let server = Server(
        name: "positronickit-test-server",
        version: "1.0.0",
        capabilities: Server.Capabilities(tools: .init(listChanged: true))
    )
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: await toolStore.tools)
    }
    await server.withMethodHandler(CallTool.self) { parameters in
        try await callTool(parameters.name, parameters.arguments)
    }
    try await server.start(transport: serverTransport)
    return InMemoryMCPServer(clientTransport: clientTransport, server: server, toolStore: toolStore)
}

/// A read-only tool definition.
func readOnlyTool(name: String, description: String = "A read-only test tool") -> Tool {
    Tool(
        name: name,
        description: description,
        inputSchema: .object(["type": "object", "properties": .object([:])]),
        annotations: Tool.Annotations(readOnlyHint: true)
    )
}

/// A tool that mutates state (no read-only annotation).
func mutatingTool(name: String, description: String = "A mutating test tool") -> Tool {
    Tool(
        name: name,
        description: description,
        inputSchema: .object(["type": "object", "properties": .object([:])]),
        annotations: Tool.Annotations(readOnlyHint: false)
    )
}

/// Maps a config and factory into a live provider for unit tests.
func makeMCPProvider(
    config: MCPServerConfiguration,
    clientTransport: InMemoryTransport,
    secretResolver: any MCPSecretResolver = MCPDictionarySecretResolver([:])
) throws -> MCPWorkspaceProvider {
    let reference = try makeMCPWorkspaceReference(name: config.name, config: config)
    return MCPWorkspaceProvider(
        reference: reference,
        configuration: config,
        secretResolver: secretResolver,
        transportFactory: { _ in clientTransport }
    )
}
