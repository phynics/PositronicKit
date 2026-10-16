import Foundation
import MCP
import PKContracts
import PKTestSupport
import PositronicKit
import Testing
@testable import PKMCP

/// Counts transport builds so a test can tell a pooled connection from per-Workspace ones.
actor MCPTransportBuildCounter {
    private(set) var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}

/// Builds a session Workspace reference that points at a profile identity, the way
/// ``WorkspaceCapability/createMCPWorkspace(_:for:)`` persists it.
func makeMCPProfileReference(
    profileID: String,
    name: String,
    location: WorkspaceReference.WorkspaceLocation = .runtime
) -> WorkspaceReference {
    WorkspaceReference(
        uri: WorkspaceURI(host: "mcp", path: name),
        location: location,
        metadata: [MCPServerProfile.metadataKey: .string(profileID)]
    )
}

private func streamableConfig(name: String, permission: MCPPermissionPolicy = .annotations) -> MCPServerConfiguration {
    MCPServerConfiguration(
        name: name,
        transport: .streamableHTTP(url: URL(string: "http://127.0.0.1:1/mcp")!, headers: [:]),
        permission: permission
    )
}

@Suite("MCP server profiles")
struct MCPServerProfileTests {
    @Test("a pooled profile shares one connection across session Workspaces")
    func pooledProfileSharesConnection() async throws {
        let server = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "echo")],
            callTool: { _, _ in CallTool.Result(content: [.text(text: "unused", annotations: nil, _meta: nil)]) }
        )
        defer { Task { await server.stop() } }

        let counter = MCPTransportBuildCounter()
        let profile = MCPServerProfile(
            id: "shared",
            configuration: streamableConfig(name: "shared"),
            sessionScope: .pooled
        )
        let factory = MCPWorkspaceFactory(
            secretResolver: MCPDictionarySecretResolver([:]),
            profiles: [profile],
            fallback: MockWorkspaceCreator(),
            transportFactory: { _ in
                _ = await counter.increment()
                return server.clientTransport
            }
        )

        let first = try factory.create(from: makeMCPProfileReference(profileID: "shared", name: "shared"))
        let second = try factory.create(from: makeMCPProfileReference(profileID: "shared", name: "shared"))

        let firstTools = try await (first as? MCPWorkspaceProvider)?.listTools()
        let secondTools = try await (second as? MCPWorkspaceProvider)?.listTools()

        #expect(firstTools?.count == 1)
        #expect(secondTools?.count == 1)
        #expect(await counter.count == 1, "a pooled profile must build one transport")
    }

    @Test("a per-Workspace profile opens one connection per session Workspace")
    func perWorkspaceProfileOpensConnectionEach() async throws {
        let firstServer = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "echo")],
            callTool: { _, _ in CallTool.Result(content: []) }
        )
        let secondServer = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "echo")],
            callTool: { _, _ in CallTool.Result(content: []) }
        )
        defer { Task { await firstServer.stop() } }
        defer { Task { await secondServer.stop() } }

        let counter = MCPTransportBuildCounter()
        let profile = MCPServerProfile(
            id: "isolated",
            configuration: streamableConfig(name: "isolated"),
            sessionScope: .perWorkspace
        )
        let factory = MCPWorkspaceFactory(
            secretResolver: MCPDictionarySecretResolver([:]),
            profiles: [profile],
            fallback: MockWorkspaceCreator(),
            transportFactory: { _ in
                let build = await counter.increment()
                return build == 1 ? firstServer.clientTransport : secondServer.clientTransport
            }
        )

        let first = try factory.create(from: makeMCPProfileReference(profileID: "isolated", name: "isolated"))
        let second = try factory.create(from: makeMCPProfileReference(profileID: "isolated", name: "isolated"))
        _ = try await (first as? MCPWorkspaceProvider)?.listTools()
        _ = try await (second as? MCPWorkspaceProvider)?.listTools()

        #expect(await counter.count == 2, "each per-Workspace provider needs its own transport")
    }

    @Test("an unregistered profile identity fails resolution")
    func unknownProfileFails() {
        let factory = MCPWorkspaceFactory(secretResolver: MCPDictionarySecretResolver([:]))
        let reference = makeMCPProfileReference(profileID: "missing", name: "missing")
        #expect(throws: MCPWorkspaceError.unknownProfile("missing")) {
            _ = try factory.create(from: reference)
        }
    }

    @Test("a profile without an explicit identity uses the server name")
    func defaultProfileIdentity() {
        let profile = MCPServerProfile(configuration: streamableConfig(name: "github"))
        #expect(profile.id == "github")
        #expect(profile.name == "github")
        #expect(profile.sessionScope == .perWorkspace)
    }

    @Test("the factory passes the workspace factory conformance suite for a profile reference")
    func factoryConformanceForProfile() throws {
        let profile = MCPServerProfile(
            id: "conform",
            configuration: streamableConfig(name: "conform"),
            sessionScope: .pooled
        )
        let factory = MCPWorkspaceFactory(
            secretResolver: MCPDictionarySecretResolver([:]),
            profiles: [profile]
        )
        try WorkspaceFactoryConformanceSuite.run(
            factory: factory,
            supportedReference: makeMCPProfileReference(profileID: "conform", name: "conform")
        )
    }

    @Test("attaching a profile persists only the identity, never the secret")
    func attachingProfilePersistsIdentityOnly() async throws {
        let server = try await makeInMemoryMCPServer(
            tools: [readOnlyTool(name: "echo")],
            callTool: { _, _ in CallTool.Result(content: []) }
        )
        defer { Task { await server.stop() } }

        let profile = MCPServerProfile(
            id: "github",
            configuration: MCPServerConfiguration(
                name: "github",
                transport: .streamableHTTP(
                    url: URL(string: "https://mcp.example.com/mcp")!,
                    headers: ["Authorization": .secret(MCPSecretReference("github-token"))]
                )
            ),
            sessionScope: .pooled
        )
        let factory = MCPWorkspaceFactory(
            secretResolver: MCPDictionarySecretResolver(["github-token": "super-secret-value"]),
            profiles: [profile],
            fallback: MockWorkspaceCreator(),
            transportFactory: { _ in server.clientTransport }
        )
        let workspaceRoot = TestRuntime.uniqueWorkspaceRoot()
        let test = TestRuntime(
            workspaceRoot: workspaceRoot,
            runtime: .init(
                workspaceProfile: .hostManaged(root: workspaceRoot),
                workspaceCreator: factory
            )
        )

        let timeline = try await test.timelines.create(title: "profile attach")
        let created = try await test.workspaces.createMCPWorkspace(profile, for: timeline.id)
        let fetched = try await test.workspaces.get(created.id, includeTools: false)

        guard case let .string(profileID)? = fetched?.metadata?[MCPServerProfile.metadataKey] else {
            Issue.record("the profile identity was not persisted")
            return
        }
        #expect(profileID == "github")
        #expect(fetched?.metadata?[MCPServerConfiguration.metadataKey] == nil)

        let json = String(decoding: try JSONEncoder().encode(fetched), as: UTF8.self)
        #expect(json.contains("github"))
        #expect(!json.contains("super-secret-value"))
    }
}
