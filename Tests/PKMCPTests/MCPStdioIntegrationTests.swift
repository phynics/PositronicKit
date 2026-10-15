import Foundation
import MCP
import PKContracts
import PositronicKit
import Testing
@testable import PKMCP

/// A minimal MCP server over stdin/stdout, used to exercise the real `StdioTransport` against a
/// child process on macOS and Linux.
private let pythonStdioServerScript = #"""
import json, sys

def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        send({
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "python-stdio", "version": "1.0.0"},
            },
        })
    elif method == "notifications/initialized":
        pass
    elif method == "tools/list":
        send({
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "tools": [
                    {
                        "name": "echo",
                        "description": "Echo text",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"text": {"type": "string"}},
                        },
                    }
                ]
            },
        })
    elif method == "tools/call":
        arguments = (message.get("params") or {}).get("arguments") or {}
        send({
            "jsonrpc": "2.0",
            "id": message["id"],
            "result": {
                "content": [{"type": "text", "text": "py:" + str(arguments.get("text", ""))}],
                "isError": False,
            },
        })
    elif "id" in message:
        send({"jsonrpc": "2.0", "id": message["id"], "result": {}})
"""#

/// Resolves `python3` from `PATH`, or `nil` when the interpreter is unavailable.
private let python3Executable: String? = {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in path.split(separator: ":") {
        let candidate = "\(directory)/python3"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}()

// The stdio transport spawns a local `python3` MCP server. It runs on macOS and Linux; it is
// skipped when no interpreter is available.
@Suite("MCP stdio integration")
struct MCPStdioIntegrationTests {
    @Test(
        "the stdio transport lists and calls tools on a child process",
        .enabled(if: python3Executable != nil)
    )
    func stdioTransportListsAndCallsTools() async throws {
        let executable = try #require(python3Executable)
        let config = MCPServerConfiguration(
            name: "stdio",
            transport: .stdio(
                executable: executable,
                arguments: ["-u", "-c", pythonStdioServerScript],
                environment: [:]
            )
        )
        let reference = try makeMCPWorkspaceReference(name: "stdio", config: config)
        let provider = MCPWorkspaceProvider(
            reference: reference,
            configuration: config,
            secretResolver: MCPDictionarySecretResolver([:]),
            transportFactory: nil
        )

        let tools = try await provider.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.toolID == "echo")

        let result = try await provider.executeTool(id: "echo", parameters: ["text": "hello"])
        #expect(result.isSuccess)
        #expect(result.output == "py:hello")
    }
}
