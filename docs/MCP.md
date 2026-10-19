# MCP workspaces

`PKMCP` connects a [Model Context Protocol](https://modelcontextprotocol.io) server as an
ordinary PositronicKit **Workspace**. The model reaches that server's tools through the existing
`call_tool` dispatcher, so MCP inherits admission-time authority capture, per-Workspace FIFO
serialization, timeouts, approval gating, and durable tool intent and result audit. No new
execution path is introduced. The provider-facing selector contains only exact, unique tool IDs
captured from the MCP server's tool list; aliases and duplicate IDs fail closed.

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

`createMCPWorkspace(_:for:)` persists the secret-free configuration on the Workspace reference and
binds the Workspace to the Timeline. Prefer a shared profile (below) when the same server serves
more than one Timeline.

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

## Share one server profile across many Timelines

One MCP server connection maps to one Workspace, and an ordinary Workspace binds exclusively to
one Timeline. A host that wants the same server on many Timelines should not hand-build a
Workspace per Timeline. `MCPServerProfile` separates the **reusable server configuration** from
the **session Workspace**: register the profile once with the factory, then attach it to any
number of Timelines. Each attach creates an ordinary session Workspace, so exclusive binding,
per-Workspace FIFO serialization, and admission-time authority are unchanged.

```swift
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
let mcp = MCPWorkspaceFactory(
    secretResolver: MCPDictionarySecretResolver([
        "github-token": ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? "",
    ]),
    profiles: [profile],
    fallback: myWorkspaceCreator
)

// Attach the same profile to every Timeline that needs it. The reference
// persists only the profile identity; the factory resolves it back.
let first = try await kit.workspaces.createMCPWorkspace(profile, for: timelineID)
_ = first.id
```

`sessionScope` decides how the transport is scoped:

| `MCPSessionScope` | Behavior | Use for |
| --- | --- | --- |
| `.perWorkspace` (default) | Every session Workspace opens its own connection and process. | Stateful servers (a browser session, a REPL) where isolation between Timelines is the point. |
| `.pooled` | Every session Workspace for the profile shares one connection. | Stateless tool catalogs where per-Timeline isolation is wasted. |

A `.pooled` connection serves its session Workspaces concurrently, so a server with per-session
state must use `.perWorkspace`. Attaching a profile the factory has not registered throws
`MCPWorkspaceError.unknownProfile`. `kit.workspaces.list()` returns the session Workspaces
individually; grouping them under their profile is deferred until a consumer needs it.

## Mapping

| MCP | PositronicKit |
| --- | --- |
| `tools/list` (paginated) | `listTools()` → `.custom(ToolDefinition)`; `inputSchema` → `parametersSchema` |
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
| Shared `MCPServerProfile` with `.perWorkspace` / `.pooled` sessions | Supported |
| Resources, prompts, sampling, elicitation, roots | Not in v1 |
| OAuth authorization flow | Not in v1; the host supplies tokens |
| Serving MCP from PositronicKit | Not in v1 |
