# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for tagged releases beginning with `1.0.0`.

## [Unreleased]

### Breaking

- Unified the tool-argument type across the execution boundary (PKAPI-001):
  `Tool.execute(parameters:)` and `Tool.summarize(parameters:result:)` now take
  `[String: AnyCodable]` (Sendable) instead of the un-Sendable `[String: Any]`, matching the
  type already used by `WorkspaceProtocol.executeTool(id:parameters:)` and
  `ToolApprovalGate.requestApproval(tool:arguments:)`. `AnyTool`'s forwarding impls and every
  built-in tool were updated. `ToolTimeoutEnforcer` now passes arguments through directly (no
  `toAnyDictionary` conversion), and `WorkspaceToolWrapper.execute` no longer wraps each value in
  `AnyCodable`. `AnyCodable` gained `ExpressibleByStringLiteral`/`Integer`/`Float`/`Boolean`
  conformances so literal argument dictionaries read identically to the old `[String: Any]` form;
  non-literal values (e.g. a `String` variable) must be wrapped explicitly (`AnyCodable(value)`).
  Custom `Tool` conformers downstream (Monad/Shuttle/Yakamoz) must update their `execute`/`
  summarize` signatures and `parametersSchema` return type when they bump to the release that
  includes this change; migration is deferred until that release is cut (consumers pin to released
  versions).
- Typed `Tool.parametersSchema` as `JSONSchema.Schema` (PKAPI-001): it was
  `[String: AnyCodable]` (a decoded JSON dict), while every other schema surface was already
  typed (`LLMToolDefinition.parameters: Schema?`, `SidecarDirective.schema: Schema`). The
  `Tool.toLLMToolDefinition()` serialization site now consumes the typed `Schema` directly with no
  encode/decode round-trip. `ToolParameterSchema` is retained as a builder helper
  (`ToolParameterSchema.object { … }.schemaDefinition`); its old `.schema` dict accessor was
  removed. `WorkspaceToolDefinition.parametersSchema` stays `[String: AnyCodable]` (it must remain
  `Codable`/`Hashable` for `ToolReference`); the `Tool`↔DTO boundary converts via
  `Schema.asDictionary` / `Schema(_:)`.

### Changed

- `Tool.canExecute()` doc comment corrected (PKAPI-001): it was documented as "whether the tool
  is currently available for execution in the given environment" but takes no environment
  parameter — no conformer depends on an injected context. The comment now reads "whether the
  tool is currently available for execution."

### Changed

- Build-surface housekeeping (PKCLEAN-009): documented in `Package.swift` why
  `PositronicKitTests` still depends on `PositronicKitExamples` — the
  `Tests/PositronicKitTests/Stories/Examples/*.swift` files exercise
  `PKPromptExamples`/`PositronicKitUsageExamples` behaviorally (not a trivial compile
  check), so dropping the dependency would lose coverage rather than relocate it.
  Confirmed `PKFastEmbed` is already target-only (no library product) and unused by
  Monad/Shuttle/Yakamoz directly; no further change needed there.

### Added

- `PKShared.LogKeys`: a caseless namespace of canonical `Logger.Metadata` key constants
  (`timelineID`, `sendID`, `turnIndex`, `toolName`, `provider`, `stage`, `errorCode`) for the
  chat turn loop. Structured-log sites across prompt assembly, LLM stream lifecycle, loop
  continuation decisions, and tool routing now use these keys (replacing the legacy
  `conversationID` synonym) so downstream consumers can correlate log lines by timeline/send/turn
  without regex.
- `TimelineToolManager.tools(inWorkspace:)` and `toolsGroupedByWorkspace()` (PKCLEAN-013): a
  read-side query exposing the per-workspace tool grouping the runtime already tracks internally
  (custom workspace tools + `.known` system tools tagged to a workspace, with resolved
  provenance). Provider/global tools are excluded. Additive; existing `getEnabledTools()`/
  `getAvailableTools()` behavior unchanged.

### Changed

- Extracted the shared compaction-pressure core and section-fingerprint into PKPrompt
  (PKDEEP2-003). `AppendPressure` (package-internal) now owns the append counters +
  `recordAppend`/`shouldCompact`/`reset` consumed by both `PromptJournal` (PKPrompt) and
  `TimelinePromptHistory` (runtime); each consumer retains its own post-compact action (base
  promotion vs. snapshot reset). The section-fingerprint helper `sectionContentHash(_:)`
  (package-internal) unifies both systems on a text-only scheme: `estimatedTokens` and the
  `type` enum are no longer part of the fingerprint, so a token-estimate delta with identical
  text no longer registers as a content change. For `.messages` content, `role`/`think`/
  `isSummary` are folded into the hash inputs so no content-bearing change is lost. This
  eliminates the cross-system divergence where a semistable section with a token-only change
  differed on the PKPrompt side but not the runtime side.
- (PKCLEAN-008) `PKOpenAIProvider.OpenAIStructuredOutputAdapter` and
  `PKOpenRouterProvider.OpenRouterStructuredOutputAdapter` were logic-identical
  copy-paste (OpenRouter mirrors OpenAI's native `json_object`/`json_schema`
  response-format support). Both are replaced by a single shared
  `PKShared.NativeJSONSchemaStructuredOutputAdapter`, which each provider now
  registers directly with `StructuredOutputAdapterRegistry`.

### Deprecated

- `PositronicKit.CompactionThresholds` is now a deprecated typealias for
  `PKPrompt.PromptJournalCompactionThresholds` (the surviving public name). The runtime's
  `TimelinePromptHistory` and `TimelinePromptHistoryRegistry` now consume
  `PromptJournalCompactionThresholds` directly. Source callers passing
  `CompactionThresholds(...)` continue to compile with a deprecation warning; migrate to
  `PromptJournalCompactionThresholds`. No downstream consumers (Monad, Shuttle, Yakamoz)
  reference either name today.

### Removed

- **Breaking:** removed `PositronicKit.sidecarsIfEnabled(_:when:)`. Consumers can inline the equivalent ternary (`isEnabled ? sidecars : []`) at the call site. Yakamoz's `YakamozRuntime.makeChatViewModel` is updated accordingly.
- **Breaking:** removed the unused `PositronicKit.PromptBuildContext` facade typealias and its intermediate `PositronicKitPromptBuildContext` alias. The canonical type remains `PromptBuildContext` in `PromptSectionProviding.swift`; conformers and callers should use that name directly.
- **Breaking:** removed `PKOpenAIProvider.OpenAIEmbeddingService`, an abandoned experiment with zero references across PositronicKit, Monad, Shuttle, or Yakamoz. Production embedding paths use `LocalEmbeddingService`/`NoOpEmbeddingService`; this was public in the 1.x line, so flag for the release captain when cutting the next minor/major.
- **Breaking:** removed `PKShared.PipelineBuilder` (unused `@resultBuilder`; pipelines are assembled imperatively via `Pipeline.add()`) and its `Pipeline.init(stages:)` convenience initializer overload.
- **Breaking:** removed the throwing `Collection.assertUniqueIDs()` overloads and `PKPrompt.CollectionUniqueIDError` (never used outside their own tests). `Collection.duplicateIDs(idKeyPath:)` is now `public` (previously internal) and remains the supported non-throwing check.
- **Breaking:** removed `Collection.duplicatePromptSectionIDs()` and `Collection.duplicateRenderedPromptSectionIDs()` typed wrappers; call `duplicateIDs(idKeyPath: \.id)` directly instead.
- (PKCLEAN-008) **Breaking:** removed `PKOpenAIProvider.OpenAIStructuredOutputAdapter` and
  `PKOpenRouterProvider.OpenRouterStructuredOutputAdapter` (superseded by
  `PKShared.NativeJSONSchemaStructuredOutputAdapter`, see Changed above).
- (PKCLEAN-008) **Breaking:** removed the public `PKShared.MessageParser` type. Its two
  methods were only ever reached through the pass-through wrappers
  `Message.parseResponse(_:)` / `Message.displayContent`; the implementations are now
  inlined directly into those `Message` members with unchanged behavior.
- (PKCLEAN-004) **Breaking:** removed the deprecated
  `AnyTool.init(_ tool: any Tool, provenance: String?)` initializer. The replacement
  `AnyTool.init(_:provenance:)` taking `ToolProvenance` (defaulting to `.global`) covers all
  cases. Zero downstream callers across Monad, Shuttle, and Yakamoz (both Yakamoz call sites
  already use the `ToolProvenance` overload), so source-compatible in practice for consumers
  pinning to released versions.
- (PKCLEAN-007) **Breaking:** removed the dead `ToolCallFormat.json` / `.xml` cases.
  They were never acted on by the runtime or any provider adapter — `.openAI` (native,
  provider-side tool calling) is the only supported format and the sole remaining case.
  `Codable` decoding is now lenient: an on-disk config predating this change may still carry a
  stale `"JSON"` or `"XML"` raw value; rather than throwing, any unrecognized raw value decodes
  to `.openAI`, so existing config files keep loading without a migration. `ollamaDefaults`'
  `toolFormat` (previously `.json`, silently ignored by the Ollama client) now defaults to
  `.openAI`. The Monad CLI config picker/migration for this collapse is tracked separately as
  `MON-PK-1` and will land after the next PositronicKit release + Monad pin bump.
- (PKCLEAN-003) **Breaking:** removed the deprecated `LLMServiceProtocol` composite protocol
  (the `@available(*, deprecated)` aggregate of `LLMStreamClient`, `LLMConfigStore`,
  `LLMUtilityClient`, and `HealthCheckable` introduced by PKARCH-004). The `PositronicKit`
  facade now types its `llmService` parameter/property as
  `any LLMStreamClient & LLMConfigStore & LLMUtilityClient` (the intersection of the three
  narrow seams; `HealthCheckable` is no longer required by the facade). `LLMService`,
  `UnconfiguredLLMService`, and `MockLLMService` still conform to the three narrow protocols,
  so callers passing those compile unchanged. Downstream migration: Monad call sites
  (`MonadServerFactory+Routes.swift`, `MonadServerFactory.swift`, `StatusAPIController.swift`,
  `ConfigurationAPIController.swift`) are tracked by `MON-PK-2`; Shuttle
  (`ShuttleShardAgentRunner.swift`, `ShuttleAgentRunnerTestSupport.swift`) and Yakamoz
  (`YakamozRuntime.swift`) migrations are not yet filed. Release-cut and consumer pin bumps
  are deferred until those land.

### Fixed

- Race/robustness sweep (PKFLAKE-003/004/005/006): `ToolTimeoutEnforcer.execute` no longer
  races two bare `Task {}` blocks inside a `withCheckedThrowingContinuation` (a double-resume
  hazard on cancellation); the tool/timeout race now reports into an `AsyncStream`, which
  tolerates a straggling loser resolving after the winner without crashing. `MiniLMEmbedder`'s
  `@unchecked Sendable` is now documented: the native bridge serializes `embed`/`embedBatch` on
  a Rust `Mutex`, and the sole production owner (`PKMiniLMPlatformBackend`, an actor) guarantees
  `deinit` never races an in-flight call. `PositronicKit.resolveContextManager` and
  `AgentInstanceManager`'s attach/detach/delete audit-log and cleanup paths no longer discard
  persistence errors via bare `try?`; failures are now logged (`.error`/`.warning`) with
  `ErrorKit.userFriendlyMessage(for:)` and identifiers, and the turn/operation proceeds exactly
  as before (hydration failure was already best-effort — a brand-new timeline legitimately has
  nothing to hydrate yet). `ContextRanker.rankMemories` gains an additive `now: @escaping () ->
  Date = Date.init` parameter (source-compatible; existing call sites are unaffected) so decay
  math is pinnable in tests instead of reading `Date()` at call time.
- `PromptDiff.publicJournalDiff` now filters its projection to semistable section IDs
  (PKDEEP2-002). Previously the runtime diff tracked changes for every `CachePolicy`,
  so stable and volatile section IDs leaked into `PromptJournalDiff`'s
  `changedSemiStableIDs` / `addedSemiStableIDs` / `removedSemiStableIDs` fields. The
  runtime diff still records all policies for cache-prefix and subtree bookkeeping;
  only the journal-facing projection narrows. `TurnLoopController` now publishes
  semistable-only overlays to `TurnInspecting`, which fixes Yakamoz's inspector
  misreporting stable/volatile churn as overlay activity.
- `SidecarSchemaComposer.containerSchema(for:)` now post-processes each directive's
  object schema so it is valid under OpenAI strict-JSON-schema mode (PKTEST-3). When a
  directive's payload schema is a JSON object with `properties`, every property name is now
  listed in its `required` array (sorted, for determinism) and `additionalProperties: false`
  is added when `@Schemable` omits it. Previously an all-optional `@Schemable` payload
  (e.g. `struct { let title: String? }`) emitted no `required` array, so under the
  unconditional `strict: true` the provider silently degraded the schema and the model
  freelanced off-schema keys (observed in production: Yakamoz SID-3 returned `{"text": "..."}`
  instead of `{"title": "..."}`). The nullable union `"type": ["string", "null"]` is
  preserved, so `null` → `.declined` still works. Leaf-scalar schemas (e.g.
  `JSONString().definition()`) have no `properties` key and pass through unchanged.
- `StructuredOutputExecution.rewriteSyntheticToolStream` no longer drops non-synthetic tool
  calls when they share a streaming chunk with synthetic `emit_structured_response` calls
  (PKTEST-2). A mixed chunk now yields two chunks: the merged synthetic content first, then a
  separate chunk carrying the non-synthetic tool-call deltas with the original `finishReason`
  and `usage`. All-synthetic and all-non-synthetic chunks are unchanged. Previously the
  non-synthetic tool calls were silently discarded whenever a synthetic call was present in
  the same chunk.

### Changed

- Internal refactor (PKCLEAN-001): split `Sources/PKOpenRouterProvider/OpenRouterClient.swift` into
  `OpenRouterClient.swift` (actor + `Attribution`) and a new `OpenRouterModels.swift` (the 14
  request/response model types), mirroring the existing `PKOllamaProvider`/`PKAnthropicProvider`
  model/client split. No public API change.
- Internal refactor (PKCLEAN-002): split the value types out of
  `Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift` into a sibling
  `TimelinePromptHistoryTypes.swift` (`PromptSectionEntry`, `PromptSnapshot`,
  `PromptHistorySectionKind`, `PromptHistoryJournalDiff`, `PromptDiff`, `PromptHistoryUpdate`,
  the deprecated `CompactionThresholds` typealias, and `RegistryEvictionPolicy`), leaving the two
  actors (`TimelinePromptHistoryRegistry`, `TimelinePromptHistory`) in the original file. No
  public API change.
- Refactor: split the monolithic `Sources/PositronicKit/PositronicKit.swift` into `PositronicKit.swift` (core facade) and `PositronicKit+Configuration.swift` (`PersistenceConfiguration`, `RuntimeConfiguration`, and their grouped initializers). Public API is unchanged except for the removed aliases above.
- Prompt assembly no longer routes section construction through the generic `Pipeline`
  machinery (PKDEEP-001). The 10 pass-through `PromptAssemblyStage` structs, the
  `PromptAssemblyContext` actor, and the `PromptAssemblyEvent` enum are gone; `PromptAssembler`
  now builds its `[any Prompt]` inline via a private `buildSections` helper.
  `PromptAssemblyOptions.overridePipeline` is replaced by `customSections:
  (@Sendable () async -> [any Prompt])?`, which supplies the sections directly and bypasses the
  default build. `ChatEngine.execute` and `TurnPreparer.prepareSession` no longer take an
  `assemblyPipeline` parameter. The diagnostic log format changes from
  `"Starting pipeline stage: <id>"`/`"Completed pipeline stage: <id> in …"` to
  `"Starting prompt section: <id>"`/`"Completed prompt section: <id> in …"`; per-section logs are
  emitted only on the default build path (not when `customSections` is supplied). The generic
  `Pipeline`/`PipelineStage` infrastructure itself is unchanged and still backs the context-
  gathering and chat-turn pipelines.
- Docs: added a doc comment on `SidecarResult.Outcome.value` documenting the per-directive
  payload-value contract — the `AnyCodable` case tag depends on the directive's schema shape
  (leaf scalar → `.string`/`.number`; `@Schemable` object → `.dictionary`), and consumers must
  not assume `AnyCodable.asString` (returns `nil` for `.dictionary`). Cites PKTEST-1.
- Internal refactor: collapsed the `TimelineCache` protocol-with-one-adapter seam back into
  `TimelineManager` (PKDEEP-002-impl, supersedes PKARCH-003). `TimelineLifecycleService` and
  `WorkspaceAttachmentService` are gone; their methods are now `private extension` files on the
  actor (`TimelineManager+Lifecycle.swift`, `TimelineManager+Attachments.swift`). The 9-method
  `TimelineCache` protocol and `FakeTimelineCache` test fake are deleted. `ContextManager` reverts
  from `package` to `internal`. `RuntimeToolPolicyFactory` is preserved (legitimate pure-helper
  extraction). All `await cache.cacheX()` hops collapse to synchronous in-actor dict access. Public
  API is unchanged.
- Internal refactor: folded `TurnPreparer` and `TurnLoopController` back into `ChatEngine` as
  `private extension` files (`ChatEngine+TurnPreparation.swift`,
  `ChatEngine+TurnLoop.swift`), following the PKDEEP-002 `TimelineManager` pattern (PKDEEP2-001,
  supersedes the PKARCH-001 split). The two single-caller helper structs are gone; their methods
  now read `self.dependencies`/`self.logger` directly. `PromptSnapshotBuilder` and
  `PartialAssistantPersistence` remain standalone internal helpers (genuinely separable — pure,
  no marshalled state). `ExternalToolOutputSubmissionGate` remains a single shared (file-scope)
  actor instance. `TurnLoopControllerTests` cases are recast at the execute level or deleted as
  duplicates of `ChatEngineFailurePersistenceTests`/`ChatEngineTests`. No public API change.

### Added

- Tests: `SidecarOutcomeContractTests` pinning the `SidecarStreamExtractor` outcome shape for
  leaf-scalar and object-schema directives, `null` → `.declined`, missing/wrong key → `.failed`,
  `Codable` round-trip preserving the `AnyCodable` case tag, and a strict-mode contract test
  asserting that composed sidecar schemas list every payload property in `required` and emit
  `additionalProperties: false` under `strict: true` (PKTEST-1 investigation; the conflict it
  surfaced is fixed by PKTEST-3).

## [1.2.0] - 2026-07-07

### Changed

- Internal refactor: split `ToolRouter` into focused execution seams behind a stable public
  surface (PKARCH-002). `ToolRouter` remains the public actor; its four former inline concerns are
  now package-internal modules in their own files: `ToolExecutor` (approval-gate check,
  tool-manager lookup, dynamic-tool priority merge, dispatch to the concrete tool),
  `ToolTimeoutEnforcer` (wall-clock timeout race, with an injectable `sleep` closure so tests can
  exercise the timeout branch with a fake clock and no `TimelineManager`), `ToolRoutingDecision`
  (extended with `resolveWorkspace` plus explicit `workspaceID` argument handling, behind a
  package `WorkspaceResolutionProvider` protocol that `TimelineManager` conforms to), and
  `ToolTurnProjector` (extended to own the `.attempting` tool-progress event). The `TimeoutRaceResolver` actor and `executeWithTimeout`/`timeoutDescription` helpers move from
  `ToolRouter.swift` to `ToolTimeoutEnforcer.swift`. Public API is unchanged.
- Internal refactor: split `TimelineManager` into three package-internal services behind a stable
  public surface (PKARCH-003). `TimelineManager` remains the public coordinator and cache owner;
  lifecycle (`createTimeline`/`hydrateTimeline`/`updateTimelineTitle`/`deleteTimeline`/
  `cleanupStaleTimelines`) is delegated to `TimelineLifecycleService`, workspace attachment
  (`attachWorkspace`/`detachWorkspace`/`getWorkspaces`/`getWorkspace`) to
  `WorkspaceAttachmentService`, and tool-policy construction (`createToolManager`) to
  `RuntimeToolPolicyFactory`. The services operate on the caches through a narrow `package`
  `TimelineCache` seam. `ContextManager` is promoted from `internal` to `package` so it can appear
  in the `TimelineCache` method signatures; this visibility change is invisible to external
  consumers. Public API is otherwise unchanged.
- Internal refactor: unbundle `InMemoryStores.swift` into per-actor files (PKARCH-006).
  The single 379-line file splits into one file per in-memory store actor
  (`InMemoryMessageStore`, `InMemoryMemoryStore`, `InMemoryAgentInstanceStore`,
  `InMemoryAgentTemplateStore`, `InMemoryRequestOriginStore`,
  `InMemoryTimelinePersistence`, `InMemoryToolPersistence`,
  `InMemoryWorkspacePersistence`). All public actors and their `package` test
  accessors are preserved verbatim; no behavioral change. Public API is unchanged.

### Added

- Structured-output adapter seam (PKARCH-005): new `StructuredOutputAdapter` protocol and
  `PreparedStructuredOutputRequest` in `PKShared`, plus `StructuredOutputAdapterRegistry` and a
  `DefaultStructuredOutputAdapter` fallback. Each built-in provider target now owns its own
  adapter implementation (`OpenAIStructuredOutputAdapter`, `OpenRouterStructuredOutputAdapter`,
  `OllamaStructuredOutputAdapter`, `AnthropicStructuredOutputAdapter`, and
  `OpenAICompatibleStructuredOutputAdapter`) and registers it alongside its client factory. The
  core runtime no longer switches on `LLMProvider` to prepare structured-output requests; it
  looks up the registered adapter and applies the prepared result. This keeps provider-specific
  structured-output logic in dedicated provider targets while allowing hosts to register custom
  adapters for arbitrary providers.
- Workspace-scoped tool grouping (PKPOST-004): new `ToolProviding` protocol and structural
  `ToolProvenance` enum in `PKShared` (`global`, `workspace(id:name:)`, `terminal(id:name:)`,
  `named(String)`). `AnyTool.provenance` is now `ToolProvenance` with a one-release deprecated
  string-init bridge. `TimelineToolManager` gains `registerToolProvider(_:id:)` /
  `unregisterToolProvider(_:)` so the runtime assembles turn tools from global tools plus
  workspace/terminal providers. `WorkspaceProtocol.executeTool(id:parameters:)` is now optional
  with a default throwing implementation; the dead stub in `Monad.LocalWorkspace` is removed
  on the consumer side (Monad commit `c69bdf2`, which adapts Monad to this `1.1.0` API — the
  `PositronicKit` default implementation supersedes the stub, so no `PositronicKit`-side removal
  was needed).
- `PKFoundationModelsProvider` (PKPOST-003): Apple's on-device Foundation Models framework as
  a provider — `FoundationModelsClient` maps `LanguageModelSession` streaming onto
  `LLMStreamChunk` via a testable session-abstraction seam, bridges PositronicKit tools into
  the framework's tool protocol (the session executes tools itself), maps
  guardrail/termination outcomes to typed `FinishReason`, and surfaces
  `SystemLanguageModel.availability` as a typed `PKError` with user-actionable guidance.
  `#if canImport(FoundationModels)`-guarded; the package builds and tests green on hosts
  without the framework, where `chatStream` throws a typed unsupported-platform error.
- `PKAnthropicProvider` (PKPOST-001): native Anthropic Messages API adapter — event-based SSE
  stream decoding (`message_start`/`content_block_delta`/`message_delta`…) mapped onto
  `LLMStreamChunk`, `stop_reason` → typed `FinishReason`, tools via `input_schema` with
  `tool_use`/`tool_result` id pairing, system messages hoisted to the top-level `system`
  param, thinking deltas surfaced, retry-gate and sanitized-error-logging parity with the
  other adapters, and a `PositronicKit(anthropicKey:)` convenience initializer. Structured
  output rides the forced synthetic-tool path (`.anthropic` shares the `openAICompatible`
  branch) since the Messages API has no `response_format`.

### Changed

- Narrowed the LLM service seam (PKARCH-004, public API refactor). The wide
  `LLMServiceProtocol` (16 requirements) is split into three focused protocols:
  - `LLMStreamClient` — streaming chat (`chatStream`, `chatStreamWithContext`) plus
    `isConfigured`/`configuration` for setup inspection.
  - `LLMConfigStore` — configuration lifecycle (`load`/`update`/`clear`/`restore`/
    `export`/`import`).
  - `LLMUtilityClient` — one-shot/utility tasks (`sendMessage`, `generateTags`,
    `generateTitle`, `evaluateRecallPerformance`, `fetchAvailableModels`).
  `LLMService` conforms to all three. `LLMServiceProtocol` is now a
  `@available(*, deprecated)` empty protocol inheriting all three plus `HealthCheckable`,
  so existing `any LLMServiceProtocol` usage still compiles with a deprecation warning.
  The structured-output, stream, and utility default-implementation extensions were
  re-targeted onto `LLMStreamClient` (and `LLMUtilityClient where Self: LLMStreamClient`
  for the utility defaults that build on `sendStructured`). `HealthCheckable` stays on
  `LLMService` directly, not on the narrow protocols. Consumers should narrow their seams
  to the smallest protocol they need (`LLMStreamClient`, `LLMConfigStore`, or
  `LLMUtilityClient`); the deprecated composite will be removed in a future release.
  Migration note: `LLMService`/`MockLLMService`/`UnconfiguredLLMService` still conform to
  `LLMServiceProtocol`, so `any LLMServiceProtocol` call sites compile unchanged (deprecation
  warnings only). `ChatEngine`, `LLMStreamingStage`, `ChatTurnPipelineBuilder`, and
  `TimelineArchiver` were narrowed to the seam they actually use.
- Deepened the ChatEngine turn-orchestration module (PKARCH-001, internal refactor — no
  public API impact). `ChatEngine` is now a thin coordinator that delegates to four focused
  internal modules behind the same seam:
  - `TurnLoopController` — the ReAct continuation loop, max-turns enforcement, and
    cancellation handling (STAB-1 partial persistence on the error path).
  - `TurnPreparer` — session preparation: saving inputs, gathering context, resolving
    session entities, and building the initial prompt snapshot.
  - `PromptSnapshotBuilder` — follow-up prompt synthesis with the incremental-string
    assembly that avoids O(n²) re-rendering (PKR-10).
  - `PartialAssistantPersistence` — STAB-1 partial-assistant persistence on stream
    failure/cancellation.
  `ChatTurnFollowUpPolicy` was already a top-level module and is unchanged. Behavior is
  preserved exactly for cancellation, partial persistence, plugin follow-up, sidecar
  validation, and prompt-history journal-diff continuity. `ChatEngine` now depends on
  `LLMStreamClient` (streaming) plus `LLMUtilityClient` (RAG tag generation in
  `TurnPreparer.fetchContext`) rather than the full `LLMServiceProtocol`.
- Filesystem tools (`ReadFileTool`, `ListDirectoryTool`, `FindFileTool`, `SearchFilesTool`,
  `SearchFileContentTool`) no longer declare a `workspaceID` schema parameter. Workspace tools
  are constructed bound to their owning workspace, so routing context is structural (provenance)
  rather than echoed per-call by the model. Historical calls with a stray `workspaceID`
  argument continue to execute.

### Fixed

- `LLMStreamingStage.handleToolCallDeltas` (PKSTREAM-001): every yielded `ToolCallDelta` now
  carries the accumulator-resolved `id` for its index — OpenAI-style continuation chunks no
  longer reach consumers with `id == nil`.

## [1.0.0] - 2026-07-05

### Added

- Transport-neutral runtime orchestration in `PositronicKit`, centered on the public
  `PositronicKit` facade plus injectable persistence, workspace, provider, and tool seams.
- Prompt composition in `PKPrompt`, including the `@PromptBuilder` DSL, prompt assembly,
  compression, render projection, and `PromptJournal` for stable-prefix journaling workflows.
- Shared contracts in `PKShared`, including LLM/provider request and stream types, tool
  contracts, structured-output helpers, logging utilities, and common error surfaces.
- `PKLocalEmbeddings` for platform-local embeddings:
  Apple Natural Language by default on Apple platforms and the host-provisioned MiniLM bridge on
  Linux or Apple builds using the `MiniLMEmbeddings` trait.
- Provider adapters for OpenAI (`PKOpenAIProvider`), OpenRouter (`PKOpenRouterProvider`), and
  Ollama (`PKOllamaProvider`), including registration APIs and convenience runtime initializers.
- `PKTestSupport` as a reusable test-support library product for downstream runtimes.
- `PositronicKitExamples` as compiling living documentation for prompt composition, runtime
  setup, structured output, tool execution, and sidecar directives.
- Sidecar directives for piggy-backed auxiliary generations on a single model turn.
- `ChatRunRequest` as the single public request surface for chat turns.

### Highlights

- Prompt DSL plus journaling support that scales from string rendering to structured assembly and
  stable-prefix prompt history management.
- ChatEngine-backed turn pipeline with explicit runtime seams for plugins, section providers,
  persistence, workspaces, and tool routing.
- Structured output support across the shared provider contracts and example flows.
- Tool routing with approval-friendly host seams, timeline/workspace-aware resolution, and
  provider-history validation before dispatch.
- Local embeddings with clear backend ownership and published platform support constraints.

### Support Matrix

| Product | Apple Platforms | Linux | Notes |
|---------|-----------------|-------|-------|
| `PositronicKit`, `PKPrompt`, `PKShared` | Supported | Supported | Core portable modules. |
| `PKLocalEmbeddings` | Supported | Supported | Apple defaults to Natural Language; Linux uses MiniLM; Apple MiniLM is trait-gated. |
| `PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider` | Supported | Supported | Optional concrete provider adapters. |
| `PKTestSupport`, `PositronicKitExamples` | Supported | Supported | Verified through the package graph and example builds. |

### Module Map

- `PositronicKit`: runtime orchestration, chat lifecycle, timeline/workspace management, tool
  routing, runtime extension points.
- `PKPrompt`: prompt DSL, assembly, rendering, compression, journaling.
- `PKShared`: API models, tool and provider contracts, structured-output utilities, shared
  logging and errors.
- `PKLocalEmbeddings`: local embedding facade over Apple Natural Language or MiniLM.
- `PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider`: optional concrete provider
  adapters and registration helpers.
- `PKTestSupport`: reusable mocks, fixtures, and runtime builders for tests.
- `PositronicKitExamples`: executable examples that mirror supported public usage.

### Known Limitations

- No native Anthropic adapter yet. Claude-family models are currently reachable through
  OpenRouter; `PKAnthropicProvider` is planned as a post-v1 minor.
- `PKINT-003` is closed as hardening coverage, but its release-blocker sibling tickets remain the
  actual v1 correctness gate for release mechanics.
- `PKINT-007` is intentionally deferred to a post-v1 additive release: consumers that rebuild
  `PositronicKit` per send must continue sharing their prompt-history registry explicitly until
  the supported registry-injection API lands.
- Apple Natural Language and MiniLM vectors are not interchangeable and must not share an index.

### Changed

- The v1 public API freeze removes deprecated compatibility shims before tagging:
  `PositronicKitCore`, the legacy `EmbeddingService` protocol, the old `TokenEstimator` re-export,
  and the `WorkspaceTool` storage wrapper.
- The README now defines the semver policy for tagged releases and names the post-v1 Anthropic
  roadmap explicitly.

### Migration Notes

- Replace any `PositronicKitCore` references with `PositronicKit`.
- Replace the removed `EmbeddingService` protocol with `EmbeddingServiceProtocol`.
- Replace `PositronicKit.TokenEstimator` imports with `PKShared.TokenEstimator`.
- Replace `WorkspaceTool` storage-wrapper usage with `ToolReference` and
  `WorkspaceToolDefinition`.

### Release Notes

PositronicKit `1.0.0` establishes the semver baseline for the shared agent runtime used by
Monad, Shuttle, and Yakamoz. The release bundles the transport-neutral runtime facade, the
`PKPrompt` composition system, provider adapters for OpenAI/OpenRouter/Ollama, local embeddings,
structured output, sidecar directives, and the `PKTestSupport` / examples products into one
documented compatibility line.

Highlights for downstream consumers:

- adopt `ChatRunRequest` as the stable request surface;
- compose prompts through `PKPrompt` and `PromptJournal`;
- rely on provider-history validation and tool-routing seams instead of host-specific forks;
- choose Apple Natural Language or MiniLM explicitly when owning vector stores.

Known caveats for the tag:

- Anthropic is still OpenRouter-only until `PKAnthropicProvider` lands;
- per-send runtime reconstruction still requires a shared prompt-history registry until the
  `PKINT-007` additive follow-up ships;
- vector stores must stay backend-specific because Apple NL and MiniLM embeddings are incompatible.
