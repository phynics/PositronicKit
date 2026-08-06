# PositronicKit v3 Vocabulary and Composition — Design

**Date:** 2026-07-12  
**Status:** Draft — pending review  
**Release:** Next major version

## Purpose

PositronicKit has accumulated multiple names for the same role and names that conceal distinct roles. v3 makes the public interface reflect one vocabulary: timelines are durable interactions, explicit language-model injection selects model behavior, workspace extension remains open to users, and tool/prompt modules name their actual responsibility.

## Global decisions

- These are direct breaking changes with no deprecation window.
- Monad, Shuttle, and Yakamoz are audited and migrated through local-path overrides before the v3 tag.
- Provider-native external SDK terms may remain inside their adapter; PositronicKit's public terminology does not inherit them.
- No new generic global registry or service locator is introduced.

## 1. Workspace extension and composition

Workspaces remain a user-implementable extension seam. The terms distinguish a persisted description from resolved behavior:

| v3 term | Current name |
| --- | --- |
| `Workspace` | `WorkspaceProtocol` |
| `WorkspaceFactory` | `WorkspaceCreating` |
| `WorkspaceStore` | `WorkspacePersistenceProtocol` |
| `WorkspaceCatalog` | `AgentWorkspaceServiceProtocol` / `AgentWorkspaceService` |
| `WorkspaceResolver` | `WorkspaceManagerProtocol` / `WorkspaceManager` |

`TimelineManager` receives `any WorkspaceResolver` directly. It does not construct a catalog/factory/resolver graph. The default graph is assembled by `PositronicKit.Configuration` or an explicit composition factory. A custom resolver contract test proves host-defined workspace behavior works without internal provisioning policy.

## 2. Timeline interaction

`Timeline` is the durable record. `TimelineManager` owns timeline lifecycle and attachments. A `TimelineDriver` is the single-timeline interaction module, replacing `Conversation`.

```swift
public struct TimelineDriver: Identifiable, Sendable {
    public let timelineID: UUID
    public func send(_ message: String) async throws -> AsyncThrowingStream<ChatEvent, Error>
    public func cancel() async
}

public extension PositronicKit {
    func openTimeline(_ id: UUID) -> TimelineDriver
}
```

`TimelineDriver` contains only a timeline ID and the kit reference; it has no mutable turn state, persistence lookup, or exposed manager. `TimelineController` in `PKObservable` replaces `ObservableConversation` and owns only UI projection/in-flight UI behavior. Remove Conversation, session wording, and session-named non-provider code/tests/docs.

## 3. Language-model composition

The facade receives one explicit model implementation, not separate stream/config/utility values and not a global provider registry.

```swift
public protocol LanguageModel: Sendable,
    LLMStreamClient,
    LLMConfigStore,
    LLMUtilityClient {}

public struct PositronicKit.ProviderConfiguration: Sendable {
    public let languageModel: any LanguageModel
}
```

Narrow capability protocols remain available for internal dependency seams and advanced adapters. `llmService` becomes `languageModel` at public composition points. `ExternalLLMProviderRegistry`, `ProviderFactoryRequest`, and provider `register()` construction paths are removed. Hosts with dynamic selection own an explicit host factory at their composition root. `ProviderHTTPTransport` remains provider-internal.

## 4. Tool terminology

| v3 term | Current name |
| --- | --- |
| `ToolSource` | `ToolProviding` |
| `ToolOrigin` | `ToolProvenance` |
| `TimelineToolRegistry` | `TimelineToolManager` |
| `ToolApprovalPolicy` | `ToolApprovalGate` |
| `ToolRouter` | unchanged |

The registry assembles and enables tools for one timeline. The router resolves and executes requested calls. A source contributes tools with an origin; “provider” remains reserved for language-model vendor adapters. Approval policy decides whether a permissioned call may execute and is distinct from approval UI.

## 5. Prompt preparation

| v3 term | Current name |
| --- | --- |
| `TurnBriefing` | retrieved/ranked turn context (new explicit output) |
| `TurnBriefingBuilder` | `ContextManager` |
| `PromptJournal` | unchanged |
| `TimelinePromptJournals` | `TimelinePromptHistoryRegistry` |
| `PromptObserver` / `PromptObserving` | `PromptInspecting` |

A briefing is selected memory/workspace material for one turn. It is deliberately not called context, which remains available for the model context window and generic execution state. A journal is an evolving cache-policy-aware record and is not literal prompt history. Timeline-keyed journal ownership stays internal unless a consumer demonstrates a real need for it.

## 6. Compatibility and implementation-surface removal

Remove without a deprecation period:

- `CompactionThresholds` and `EmptySection` aliases.
- The flat `LLMConfiguration` initializer and write-through compatibility properties.
- Mutating `TimelineManager.getTimeline(id:)`; retain pure `timeline(id:)` and explicit `touchTimeline(id:)`.
- Public visibility on implementation details such as `StreamingParser`, `VectorMath`, and terminal-color formatting when the consumer audit confirms no external use.

`ToolOutputParser` remains governed by PKHYG-005 and is not part of this refactor.

## 7. Provider variance is logged, not rejected

The common LanguageModel interface stays intact. A provider that ignores or coerces a requested
tool option, response format, or generation parameter emits one structured warning per turn. The
warning includes provider/model identity, capability/parameter name, requested value category,
reason, timeline ID, and turn index; it never includes prompt, tool arguments, or response content.
Provider contract tests assert both the retained behavior and the warning. Public docs publish a
provider capability matrix.

## 8. PKUtilities module split

Create public `PKUtilities`, depending downward on `PKShared`. `PKShared` owns contracts, domain
types, errors, schemas, and tool contracts. `PKUtilities` owns cross-cutting observability,
asynchronous/pipeline helpers, redaction, and concrete filesystem tools. `PKShared` never imports
`PKUtilities`; this keeps a clean acyclic dependency graph.

## 9. TimelineManager is a deep public lifecycle module

TimelineManager remains public for lifecycle, attachments, lookup, and explicit touch operations.
It does not expose its injected WorkspaceResolver, context builder, or per-timeline tool registry.
TimelineDriver owns normal turn interaction; configuration owns custom workspace/tool/context
composition. No internal forwarding-service split is reintroduced.

## 10. Provider adapters are leaf targets

Move LanguageModel and its narrow capability contracts to PKShared. Provider targets depend on
PKShared and PKUtilities, not PositronicKit. Concrete clients implement LanguageModel directly.
Provider convenience extensions on PositronicKit are removed because hosts construct and inject the
client explicitly.

## 11. Tool erasure captures immutable identity and origin

Tool identity is an explicit Tool interface member with a default derived from `callName`. AnyTool
captures immutable ToolReference and ToolOrigin at erasure. Delete `ToolReferenceProviding` and its
dynamic cast fallback. Tool sources apply their origin during erasure rather than mutate an already
erased tool.

## 12. Hypothetical persistence seams are removed or proven

Audit `AgentInstanceStoreProtocol` and `RequestOriginStoreProtocol` across the package and all three
consumers. A zero-consumer protocol is deleted with mocks/tests. A retained protocol must have a
real consumer, a concrete adapter, and a contract test; hypothetical future extensibility is not a
reason to publish it.

## Explicit removals and migration work

- Remove `Conversation`, `ObservableConversation`, and all `newConversation`/`conversation` vending.
- Remove public compatibility aliases/accessors approved earlier: `CompactionThresholds`, `EmptySection`, legacy `LLMConfiguration` proxies/initializer, and mutating `getTimeline(id:)`.
- Rename all terms in the five tables, tests, examples, DocC, and downstream consumers.
- Delete global provider registration and migrate dynamic selection into host composition roots.
- Migrate all compatibility removals, the PKUtilities target split, and narrowed TimelineManager access.
- Document ignored-provider-option warnings and the provider capability matrix.
- Remove provider-to-core target dependencies and dynamic AnyTool identity lookup.
- Update CHANGELOG and a v3 migration guide with old-to-new symbol mappings and behavior changes.

## Non-goals

- Re-splitting TimelineManager into internal forwarding modules.
- Making provider transport configurable by package users.
- Replacing provider-native SDK session terms inside provider adapters.
- Changing `ToolOutputParser` behavior here; that is PKHYG-005.
- Renaming prompt internals beyond the approved roles without a demonstrated external seam.

## Verification

- Each migrated downstream consumer compiles/tests against a local PositronicKit override before the v3 tag.
- A custom WorkspaceResolver contract test proves the workspace extension seam.
- TimelineDriver tests cover send/cancel with no local mutable state; TimelineController tests cover UI projection.
- LanguageModel direct injection tests cover provider construction without global registration.
- Tool registry/router/policy tests prove the renamed roles preserve registration, provenance/origin, approval, and execution behavior.
- Prompt briefing/journal tests prove output and cache-compaction behavior survive rename.
- Module dependency tests prove PKShared does not import PKUtilities and provider targets do not import PositronicKit.
- Provider tests prove unsupported options produce safe structured warnings without payload leakage.
- Persistence-seam audit results prove every retained public protocol has a real adapter and contract test.
- `make verify` passes before release; release notes enumerate every source-breaking migration.
