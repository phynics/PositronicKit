# Migrating to PositronicKit 7.0

PositronicKit 7.0 is a major release. It removes public API that the runtime never read, moves
runtime vocabulary out of `PKContracts`, replaces the fork API, and makes the runtime own a smaller
prompt and model-client surface. The 6.1.0 release already broke the documented minor-release rule;
7.0.0 is the supported upgrade target for both 6.0.x and 6.1.0 consumers.

This guide describes the released 7.0.0 surface. It does not describe unreleased follow-up work.
Every `swift` example is compiled by `make verify-documentation`; `swift skip` examples show API
that 7.0 removed and are syntax-checked only.

## Upgrade the package pin

```swift skip
.package(url: "https://github.com/phynics/PositronicKit.git", from: "7.0.0")
```

Then build the application and fix the errors in the sections below. The compiler is the reliable
inventory of removed symbols; this guide explains the replacements.

## Start with the module move

`PKContracts` is now the runtime-neutral contract module only. Runtime entities and events live in
`PositronicKit`. If a file imports `PKContracts` and names `Agent`, `TurnEvent`, a Sidecar value, or
Workspace routing, add `import PositronicKit`.

`PKContracts` keeps model messages, tool definitions and results, structured output, embeddings,
and diagnostics. It still imports no PositronicKit target.

```swift skip
import PKContracts

func acceptsMovedTypes(
    _ agent: Agent,
    _ event: TurnEvent,
    _ workspace: WorkspaceReference
) {
    _ = agent
    _ = event
    _ = workspace
}
```

```swift
import PKContracts
import PositronicKit

let definition = ToolDefinition(
    id: "lookup",
    name: "lookup",
    description: "Looks up one value."
)
let reference = ToolReference.custom(definition: definition)
let event: TurnEvent? = nil
_ = reference
_ = event
```

The table lists the moved types that account for the common 6.1.0 compile failures.

| Type or family | 6.1.0 module | 7.0 module |
| --- | --- | --- |
| `Agent`, `AgentTemplate`, `AgentLifecycleState` | `PKContracts` | `PositronicKit` |
| `TurnEvent`, `TurnIdentity`, `TurnSnapshot`, `TurnDiagnostic`, `TurnContextSnapshot` | `PKContracts` | `PositronicKit` |
| `SidecarCompletion`, `SidecarDelta`, `SidecarDirective`, `SidecarResult` | `PKContracts` | `PositronicKit` |
| `WorkspaceReference`, `WorkspaceURI`, `WorkspaceToolCandidate`, `WorkspaceToolRouting` | `PKContracts` | `PositronicKit` |
| `ToolCallDelta`, `ToolCallRecord`, `ToolResultRecord`, `ToolExecutionStatus` | `PKContracts` | `PositronicKit` |
| `TurnDegradationPolicy`, `TurnDependency`, `RequestOriginIdentity`, `AudioOutputSnapshot` | `PKContracts` | `PositronicKit` |

## Remove host-settings and utility-generation assumptions (#269)

The runtime no longer stores application settings or generates titles and tags. Keep settings in
your own store, then construct `LLMService` with a configuration value and a pinned client set.
`LLMConfiguration` remains `Codable`.

```swift skip
let service = LLMService(storage: configurationStore)
try await service.loadConfiguration()
let tags = try await utilityGenerator.generateTags(for: "release notes")
```

```swift
let service = LLMService(
    configuration: provider.configuration,
    clients: LLMClientSet(primary: provider.client)
)
_ = service
```

`updateConfiguration(_:)` replaces the configuration but keeps the same clients. `LLMService` still
provides readiness, health, and available-model queries.

## Rebuild repository conformers for exact Turn membership (#247)

`TimelineRuntimeRepository` requires `recordTurnMessage(_:turnID:)`. Record the membership row in
the same transaction as the message write, at admission, intermediate assistant and tool writes,
and the terminal commit. Do not implement it as a second `saveMessage` call.

```swift skip
final class MyTimelineRepository: TimelineRuntimeRepository {
    func saveMessage(_ message: TimelineMessage) async throws {
        try await database.save(message)
    }
}
```

```swift
func recordMembership(
    _ repository: any TimelineRuntimeRepository,
    message: TimelineMessage,
    turnID: UUID
) async throws {
    try await repository.recordTurnMessage(message, turnID: turnID)
    _ = try await repository.fetchTurnMessages(turnID: turnID)
}
_ = recordMembership
```

A `nil` membership list means the record predates membership tracking. An empty list means the Turn
produced no messages. `fetchTurnMessages(turnID:)` throws `memberMessageMissing` if a recorded
member is no longer durable.

The conformance suite in `PKTestSupport` checks this invariant. Run it against your repository.

## Drop summary storage from repository conformers (#270)

`TimelineSummaryStore` is gone, along with the `summaryStorage:` conformance parameter and
`TimelineSummaryError.summarySourceMissing`. The runtime never read summaries. Keep your own
summary pipeline and the `TimelineSummary` value if you use them.

```swift skip
final class MyTimelineRepository: TimelineRuntimeRepository, TimelineSummaryStore {
    func saveSummary(_ summary: TimelineSummary) async throws {}
    func fetchSummaries(for timelineID: UUID) async throws -> [TimelineSummary] { [] }
}
```

```swift
struct MySummaryStore {
    func save(_ summary: TimelineSummary) async throws {}
    func summaries(for timelineID: UUID) async throws -> [TimelineSummary] { [] }
}
_ = MySummaryStore()
```

The store protocols also lose requirements that the runtime never called:
`TimelinePersistenceProtocol.pruneTimelines`, `TimelineMessageStoreProtocol.deleteMessages`,
`TimelineMessageStoreProtocol.pruneMessages`, `TimelineMessageStoreProtocol.fetchSnapshots`, and
`AgentStoreProtocol.fetchTimelines(attachedToAgent:)`. Remove those methods from conformers when the
compiler asks, or keep them as your own API.

Durable persistence remains a host responsibility. 7.0 ships no first-party durable store. Supply a
`TimelineRuntimeRepository` over your database and mark its durability accurately so
`PersistenceConfiguration.validateDurability()` can report mixed configurations.

## Replace the model-client resolver seam (#311)

`LLMClientResolving` and `FixedClientsResolver` are removed. Build one `LLMClientSet` and pass it to
`LLMService`. The set is pinned for the service lifetime.

```swift skip
let service = LLMService(
    configuration: configuration,
    clientResolver: resolver
)
```

```swift
let service = LLMService(
    configuration: provider.configuration,
    clients: LLMClientSet(primary: provider.client)
)
_ = service
```

Use `.utility` and `.fast` only when those tiers have a dedicated client; both fall back to
`.primary`. `LLMClientSet.empty` is available for an intentionally unconfigured service.

Use the throwing fold when a one-shot response must not treat an empty stream as success:

```swift
let chunks: [LLMStreamChunk] = []
let response = try LLMStreamChunk.folding(chunks, provider: "openai")
_ = response
```

An empty stream throws `LLMServiceError.emptyResponse(provider:)`. The nonthrowing
`folding(_:)` overload still returns an optional.

`kit.model` now passes `idleTimeout: nil` through to the runtime's configured
`RuntimeConfiguration.streamTimeout`. If you relied on an implicit 60-second one-shot timeout, set
`idleTimeout` explicitly or configure `streamTimeout` at the runtime.

## Use the rebuilt OpenAI and OpenRouter providers (#274)

`PKOpenAIProvider` no longer depends on `MacPaw/OpenAI`. The package-scoped `toOpenAI...` conversion
extensions are removed. Import `PKOpenAIProvider` and use the provider-neutral message and tool
contracts, or `PKOpenAI.makeConfiguredProvider`.

```swift skip
let params = try messages.map { try $0.toOpenAIMessageParam() }
let query = ChatQuery(messages: params, model: .gpt4o)
```

```swift
import PKOpenAIProvider

let client = OpenAIClient(
    apiKey: "sk-replace-me",
    modelName: "gpt-4o",
    api: .responses
)
let response = try await client.chatCompletion(
    messages: [LLMMessage(role: .user, content: "Summarize this note.")],
    tools: nil,
    toolChoice: nil,
    responseFormat: nil,
    generationParameters: nil
)
_ = response
```

`OpenAIAPI` selects the transport: `.automatic` uses Responses for `api.openai.com` and Chat
Completions for other hosts, `.responses` forces Responses, and `.chatCompletions` forces Chat
Completions. Audio output always uses Chat Completions. `PKOpenRouterProvider` is a thin preset over
the same Chat Completions core and keeps its attribution headers.

## Stop relying on runtime prompt state (#277, #287, #293, #294)

The runtime no longer imports `PKPrompt`. It builds provider requests from an internal tiered
layout, and the public runtime prompt-section builders are gone. Use `PKPrompt` for prompt
authoring, assembly, compression, and journaling outside the Turn loop.

```swift
import PKPrompt

let prompt = AnyPrompt.build {
    SystemPrompt("You are a careful assistant.")
    UserPrompt("Summarize the release notes.")
}
let assembled = try prompt.assemblePrompt()
let rendered = await assembled.render()
_ = rendered
```

The runtime holds no journal or append-pressure state. `TimelinePromptJournals` is removed. The only
cross-round prompt state is an internal per-Timeline `TierFingerprint` used for
`PromptCacheReport` reset accounting.

The runtime also no longer compresses or summarizes history (#294). An over-budget Turn applies a
configured `TurnHistoryProjectionSource`, trims history stepwise at a tool-transaction boundary, and
then fails with `TurnError.promptExceedsContextWindow(estimated:limit:)` if the non-history tiers
alone exceed the budget. It does not silently drop a section. Keep `PKPrompt` compression in your
own prompt pipeline if you need it.

Per-Turn context still exists. Implement `TurnContextSource` when you need namespaced contributions
inside a runtime Turn.

```swift
struct HostTurnContext: TurnContextSource {
    func contributions(
        for request: TurnContextRequest
    ) async throws -> [TurnContextContribution] {
        [try TurnContextContribution(
            namespace: "host",
            key: "current-request",
            text: request.message
        )]
    }
}
let customization = RuntimeCustomization(turnContextSource: HostTurnContext())
_ = customization
```

The tiered layout still puts tools first, then stable system, semi-stable system, history, volatile
Turn context, and the current query. A per-Turn context change therefore does not reset the whole
prompt prefix, but changing the tool set still resets reuse for the prefix that follows it.

## Supply the instructions and context the runtime no longer invents (#288, #289)

`DefaultInstructions` is removed. A Turn with no host instructions and no Agent context sends an
empty stable system tier instead of the old bundled persona. Put identity and guidance in the
Agent's stored fields through an `AgentContextSource`, in `TurnContextSource`, or directly in a
direct Turn.

```swift
let context = DirectTurnContext(
    systemInstructions: "You are a careful release assistant."
)
_ = context
```

Filesystem Agent conventions moved to the optional `PKAgentFiles` product. `DefaultAgentContextSource`
is gone. The runtime default, `IdentityAgentContextSource`, returns only the Agent's stored name,
description, and instructions.

```swift
import PKAgentFiles
import PositronicKit

let persistence = PKRuntime.PersistenceConfiguration.inMemory()
let runtime = PKRuntime.RuntimeConfiguration.agentFiles(
    persistence: persistence,
    workspaceProfile: .hostManaged(root: myWorkspaceRoot, seedNotes: .default)
)
let kit = PKRuntime(configuration: .init(
    provider: provider,
    persistence: persistence,
    runtime: runtime
))
_ = kit
```

`PKAgentFiles` supplies `FileSystemAgentContextSource`, the Agent-workspace seed, and the
protected-path write gate. The runtime default writes no identity file and no note templates.

`WorkspaceProfile` no longer seeds Timeline notes by default. The default is
`WorkspaceSeedNotes.none` for both `.hostManaged` and `.ephemeralWorkspace`. Pass
`seedNotes: .default` (or `PKAgentFiles.seedNotes`) to restore `Welcome.md` and `Project.md`.
`RuntimeToolPolicy.protectedPrimaryWorkspacePaths` defaults to empty, so no write is gated unless
the host supplies paths.

## Use one-shot message generation when you do not need a Timeline (#290)

Use `kit.model.generate(messages:...)` when the host owns the conversation and only needs a model
response. It does not create or update a Timeline or Agent, and it does not execute tool calls.

```swift
let answer = try await kit.model.generate(
    messages: [LLMMessage(role: .user, content: "Summarize this note.")],
    tools: nil,
    toolChoice: nil,
    responseFormat: nil
)
_ = answer
```

`generate` returns complete `LLMResponse.toolCalls` in provider order. A host that runs a tool round
correlates the returned calls with `LLMToolCall.id` and sends `.tool` messages back in the next
call. An application that needs no runtime at all can depend on `PKContracts` and one provider
product, without importing `PositronicKit`.

## Import experimental embeddings and sibling requests explicitly (#268)

Experimental public surfaces stay behind `@_spi(Experimental)`. In 7.0 they are the runtime-neutral
embedding contract and `TimelineHandle.siblingRequest(...)`; `TurnHistoryProjectionSource` is stable
public API. Add the SPI attribute to the module import when you use an experimental surface.

```swift
@_spi(Experimental) import PKContracts

let budget = EmbeddingInputBudget.default
_ = budget
```

```swift
@_spi(Experimental) import PositronicKit

let request = try await timeline.siblingRequest(appending: [])
_ = request
```

A sibling request needs a cached prefix. Enable it with
`RuntimeConfiguration(retainsSiblingPrefix: true)` and call it after a completed model round. It
writes nothing to Timeline history and does not take the Timeline authority lane.

## Replace the old fork API (#263)

If you tracked pre-RC `main`, `PKRuntime.fork(from:context:)`, `TimelineFork`,
`TimelineController(fork:)`, and `TurnOptions.prependingTools` are removed. 6.1.0 consumers did not
have this API.

A fork is now an ordinary detached, private, ephemeral `TimelineHandle` in the same runtime. Run
ordinary direct Turns on it. The runtime copies the source's semantic history with fresh message IDs
and `TimelineForkOrigin` lineage, injects no tools, and deletes the Timeline when the last handle is
released.

```swift skip
let fork = try await kit.fork(from: timelineID, context: context)
let turn = try await fork.startTurn("Audit this answer.")
```

```swift
let context = DirectTurnContext(systemInstructions: "Audit the answer.")
let fork = try await kit.timelines.fork(from: timelineID)
let turn = try await fork.startDirectTurn(
    "Audit the answer.",
    context: context,
    options: TurnOptions(tools: RuntimeToolSets.readOnlyFilesystem(root: myWorkspaceRoot))
)
_ = turn
```

`timelines.list()` excludes ephemeral Timelines unless you pass `includeEphemeral: true`.
`TimelineRuntimeRepository` conformers must implement `deleteEphemeralTimeline(id:)` and
`purgeEphemeralTimelines()`; the runtime sweeps orphaned ephemeral Timelines at startup.
`PKObservable.TimelineController` binds a fork through its existing direct-path initializer.

## Adopt the stable history-projection seam (#264)

`TurnHistoryProjectionSource` is stable public API in 7.0. It replaces a covered prefix with one
bounded text replacement before budget trimming. Projection never rewrites durable history. Return
`nil` to leave history unchanged.

```swift
struct HostProjectionSource: TurnHistoryProjectionSource {
    func projection(
        for request: TurnHistoryProjectionRequest
    ) async throws -> TurnHistoryProjection? {
        guard let first = request.messages.first?.id else { return nil }
        return TurnHistoryProjection(
            coveredMessageIDs: [first],
            replacement: "Earlier conversation summarized.",
            firstRetainedMessageID: request.messages.dropFirst().first?.id
        )
    }
}
let customization = RuntimeCustomization(
    turnHistoryProjectionSource: HostProjectionSource()
)
_ = customization
```

Descriptors carry the full multimodal `MessageContent`, including image and audio parts. The
replacement itself is plain text and is capped at 32,768 characters. Coverage must be a contiguous
prefix that ends at a tool-transaction boundary and must not include the current input. A failing
source is optional by default and records `TurnNoticeCode.historyProjectionFailed`; set
`failureRequirement` to `.required` to fail the Turn instead.

## Replace Workspace tool definitions and routing (#314)

`WorkspaceToolDefinition` is now the neutral `ToolDefinition` in `PKContracts`. `ToolReference`
uses it for custom tools. `ToolResult` no longer carries Workspace provenance.

```swift skip
let definition = WorkspaceToolDefinition(
    id: "lookup",
    name: "lookup",
    description: "Looks up one value."
)
let result = ToolResult.success(
    "ok",
    workspaceID: workspaceID,
    workspaceRouting: .explicit
)
```

```swift
let definition = ToolDefinition(
    id: "lookup",
    name: "lookup",
    description: "Looks up one value."
)
let reference = ToolReference.custom(definition: definition)
let result = ToolResult.success("ok")
_ = reference
_ = result
```

Read Workspace provenance from the terminal event instead:
`ToolExecutionStatus.workspaceSucceeded(result:workspaceID:routing:)`,
`.workspaceFailed(...)`, or `.workspacePersistenceFailed(...)`. The resolved
`WorkspaceToolCandidate` and `WorkspaceToolRouting` values remain available in `PositronicKit` for
host inspection and tests.

## Account for the changed provider and runtime behavior

These changes do not require a new type, but they can change observed outcomes:

- A Turn captures provider configuration and execution authority inside the admission lane and
  freezes that snapshot for its lifetime (#307). A configuration replacement or Workspace binding
  change during preparation cannot switch the active Turn's model or Workspace.
- Tool results reloaded from history keep their `.tool` role and original call ID, so follow-up
  requests replay the assistant call and matching result together (#366).
- OpenAI Responses failures surface as `LLMServiceError` instead of a clean EOF, an incomplete
  response carries its finish reason and usage, and a stream without a terminal event fails
  (#369). OpenAI Responses usage is read from the nested completion envelope (#364).
- Stateless OpenAI Responses follow-ups replay each assistant `function_call` with its original
  name, arguments, and call ID (#368).
- Workspace `call_tool` selectors enumerate only unique captured call names. Display-name aliases
  and duplicate identifiers are rejected (#378).

## Verify the upgrade

Run the deterministic checks that apply to your integration:

```sh
swift build
swift test
```

For downstream persistence and test harnesses, also run the `PKTestSupport` conformance suites
against your stores. For a host-defined runtime without `kit.agents`, see
`Tests/PositronicKitTests/Stories/Runtime/HostDefinedRuntimeStoriesTests.swift`. For a generic
model-only consumer, see `Tests/GenericModelConsumerTests/GenericModelConsumerTests.swift`. For
managed-Agent admission, lifecycle, and retirement, see
`Tests/PositronicKitTests/Agents/AgentContextLifecycleTests.swift` and
`Tests/PositronicKitTests/Stories/Runtime/PublicRuntimeStoriesTests.swift`.
