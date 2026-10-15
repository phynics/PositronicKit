import Foundation
import PKContracts
import Testing
@testable import PKMCP
import PositronicKit

@Suite("MCP configuration")
struct MCPConfigurationTests {
    @Test("a configured secret persists only its reference, never its value")
    func persistedReferenceRedactsSecretValue() throws {
        let config = MCPServerConfiguration(
            name: "github",
            transport: .streamableHTTP(
                url: URL(string: "https://mcp.example.com/mcp")!,
                headers: [
                    "Authorization": .secret(MCPSecretReference("github-token")),
                    "X-Public": "public-value",
                ]
            ),
            permission: .always,
            callTimeout: .seconds(30)
        )
        let reference = try makeMCPWorkspaceReference(name: "github", config: config)
        let encoded = try JSONEncoder().encode(reference)
        let json = String(decoding: encoded, as: UTF8.self)

        #expect(json.contains("github-token"))
        #expect(json.contains("public-value"))
        #expect(!json.contains("super-secret-value"))
        // The literal case never appears for a `.secret` value.
        #expect(!json.contains("super-secret-value"))
    }

    @Test("a configuration round-trips through workspace metadata")
    func configurationRoundTripsThroughMetadata() throws {
        let config = MCPServerConfiguration(
            name: "local",
            transport: .stdio(
                executable: "/usr/bin/env",
                arguments: ["node", "server.js"],
                environment: ["TOKEN": .secret(MCPSecretReference("local-token")), "MODE": "test"]
            ),
            permission: .annotations,
            callTimeout: .milliseconds(1500)
        )
        let reference = try makeMCPWorkspaceReference(name: "local", config: config)
        let decoded = try reference.mcpServerConfiguration()
        #expect(decoded == config)
    }

    @Test("missing metadata throws invalidConfiguration")
    func missingMetadataThrows() {
        let reference = WorkspaceReference(
            uri: WorkspaceURI(host: "mcp", path: "absent"),
            location: .runtime
        )
        #expect(throws: MCPWorkspaceError.self) {
            _ = try reference.mcpServerConfiguration()
        }
    }

    @Test("dictionary secret resolver returns known keys and rejects unknown keys")
    func dictionaryResolver() async throws {
        let resolver = MCPDictionarySecretResolver(["known": "value"])
        #expect(try await resolver.resolveSecret(MCPSecretReference("known")) == "value")
        await #expect(throws: MCPWorkspaceError.secretResolutionFailed(key: "missing")) {
            _ = try await resolver.resolveSecret(MCPSecretReference("missing"))
        }
    }

    @Test("secret values accept string literals for non-secret values")
    func secretValueLiteral() {
        let value: MCPSecretValue = "literal"
        #expect(value == .value("literal"))
    }
}
