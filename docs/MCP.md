# MCP workspaces

`PKMCP` connects a [Model Context Protocol](https://modelcontextprotocol.io) server as an
ordinary PositronicKit **Workspace**. The model reaches that server's tools through the existing
`call_tool` dispatcher, so MCP inherits admission-time authority capture, per-Workspace FIFO
serialization, timeouts, approval gating, and durable tool intent and result audit. No new
execution path is introduced.

`PKMCP` is an optional runtime adapter. It imports `PositronicKit`, pins the official
[`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) at
`0.12.1`, and is never imported by the runtime or a provider.

## Install

Add the product to the targets that need it:

```swift skip
.package(url: "https://github.com/phynics/PositronicKit.git", from: "7.0.0")
```

```swift skip
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "PositronicKit", package: "PositronicKit"),
        .product(name: "PKMCP", package: "PositronicKit"),
    ]
)
```

## Configure the runtime

The runtime resolves every Workspace through one factory, so wrap the MCP factory around the
factory the runtime would otherwise use. Non-MCP references delegate to the fallback.

```swift
let mcp = MCPWorkspaceFactory(
    secretResolver: MCPDictionarySecretResolver([
        "github-token": ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? "",
    ]),
    fallback: myWorkspaceCreator
)
_ = PKRuntime(configuration: .init(
    languageModel: myLanguageModel,
    persistence: .inMemory(),
    runtime: .init(workspaceCreator: mcp)
))
```

## Connect a server

One MCP server connection maps to one Workspace. `createMCPWorkspace(_:for:)` persists the
secret-free configuration on the Workspace reference and binds the Workspace to the Timeline.

```swift
let configuration = MCPServerConfiguration(
    name: "github",
    transport: .streamableHTTP(
        url: URL(string: "https://mcp.example.com/mcp")!,
        headers: ["Authorization": .secret(MCPSecretReference("github-token"))]
    ),
    permission: .annotations,
    callTimeout: .seconds(30)
)
let workspace = try await kit.workspaces.createMCPWorkspace(configuration, for: timelineID)
_ = workspace.id
```

A local server uses the stdio transport. It spawns a process and passes its standard streams to
the SDK. The transport is available on macOS and Linux; it reports
`MCPWorkspaceError.unsupportedTransport` on platforms without `Process`.

```swift
let local = MCPServerConfiguration(
    name: "filesystem",
    transport: .stdio(
        executable: "/usr/local/bin/mcp-filesystem",
        arguments: ["--root", "/srv/data"],
        environment: ["LOG_LEVEL": "info"]
    )
)
_ = try await kit.workspaces.createMCPWorkspace(local, for: timelineID)
```

## Mapping

| MCP | PositronicKit |
| --- | --- |
| `tools/list` (paginated) | `listTools()` → `.custom(WorkspaceToolDefinition)`; `inputSchema` → `parametersSchema` |
| `annotations.readOnlyHint` | `requiresPermission` under the `.annotations` policy |
| `tools/call` `content[]` | `ToolResult.output`; text parts are joined, non-text parts become typed placeholder lines |
| `tools/call` `isError: true` | `ToolResult(isSuccess: false)` |
| `notifications/tools/list_changed` | Invalidates the cached list for the **next** Turn's catalog capture |
| JSON-RPC or transport errors | A model-facing `ToolResult` failure; the connection is marked unhealthy |
| Turn cancellation | `notifications/cancelled` for the in-flight request id |

## Approval policy

Annotations are untrusted hints, so `MCPPermissionPolicy` lets the host override them:

- `.annotations` (default) requires approval unless `readOnlyHint` is exactly `true`.
- `.always` requires approval for every tool.
- `.never` never requires approval.

Approval is enforced by the runtime's `ToolApprovalPolicy`; the MCP policy only selects which
tools carry `requiresPermission`.

## Secrets

A `WorkspaceReference` must never persist secret material. Headers and environment values are
`MCPSecretValue` values: `.value("literal")` for non-secret values, or
`.secret(MCPSecretReference("key"))` for host-resolved secrets. The persisted reference contains
only the reference key; `MCPSecretResolver.resolveSecret(_:)` supplies the value at connect time.

## Supported MCP features

| Area | Status |
| --- | --- |
| Tools (`tools/list`, `tools/call`, cancellation) | Supported |
| Tool annotations | Used for the approval policy |
| `notifications/tools/list_changed` | Supported (next-Turn invalidation) |
| Streamable HTTP transport | Supported |
| stdio transport | macOS and Linux |
| Resources, prompts, sampling, elicitation, roots | Not in v1 |
| OAuth authorization flow | Not in v1; the host supplies tokens |
| Serving MCP from PositronicKit | Not in v1 |
