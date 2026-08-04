# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for tagged releases beginning with `1.0.0`.

## [Unreleased]

### Added

- **Core API clarity (PKAPI-001)**: added canonical `ID`/`IDs` identifier spellings,
  noun-style LLM/workspace/agent queries, `make…` factories, and labeled vector similarity
  arguments. Deprecated 3.x forwarding APIs remain source-compatible, and existing serialized
  keys are preserved explicitly.

- **Code review cleanup (PKCR-001, PKCR-003, PKCR-004, PKCR-006, PKCR-007,
  PKCR-009, PKCR-010)**: removed unadopted tool-context infrastructure and unused
  imports, consolidated provider stream/HTTP helpers, split large runtime files,
  centralized facade dependency wiring, and replaced the retry-default force try
  and streaming-parser magic threshold. Dynamic sidecar schema dictionaries remain
  intentional because they represent provider/LLM-defined JSON.

- **Duplicate-content retry gate (PKCR-005)**: new public `DuplicateContentRetryGate`
  type in `PKUtilities` encapsulates the duplicate-content retry gate logic that was
  previously duplicated (as a private `Mutex<Bool>` + `markYieldedIfNeeded` helper) in the
  Ollama and Anthropic provider clients. Both clients now construct a
  `DuplicateContentRetryGate` and route through `gate.shouldRetry(error:)` /
  `gate.markYieldedIfNeeded(_:)`; the OpenRouter client's separate
  `LLMToolCallRecoveryState` mechanism is unaffected. Streaming retry behavior is
  preserved exactly.

### Changed

- **Fluent PKPrompt APIs (PKAPI-002)**: added explicit truncation retention, journal reset,
  `ForEach`, token-budget result, and `nodeID` APIs. Existing Boolean truncation payloads and
  encoded enum representations remain compatible; legacy reset, loop, token-budget, and
  `nodeId` entry points forward to the canonical forms, and compression reports continue to
  encode the `"nodeId"` key.

- **Provider and support API clarity (PKAPI-003)**: provider factories now use
  `makeClientAndRegisterStructuredOutputAdapter(configuration:)` so their global registry
  mutation is visible at the call site; `LocalEmbeddingService` consistently uses
  `miniLMModelDirectory:` across platforms; Foundation Models session-factory closure roles are
  named; and `TestRuntime.positronicKit` exposes its stored facade as noun-like state. Existing
  `makeClient(configuration:)`, Linux `modelDirectory:`, and `buildCore()` APIs remain as
  deprecated forwarding shims. Every `PKFastEmbedError` case is now documented; associated-value
  labels remain intentionally unchanged for source compatibility. Role labels (`message`,
  `statusCode`, and `validationError`) are deferred to the next major release.

- **Split turn-preparation file (PKCR-008)**: The private `TurnIdempotencyGate`
  and `ExternalToolOutputSubmissionGate` actors (plus the `ReservedToolOutput`
  struct) have been extracted from `ChatEngine+TurnPreparation.swift` into their
  own files (`TurnIdempotencyGate.swift`, `ExternalToolOutputSubmissionGate.swift`).
  Their file-global singletons are now `static let shared` on each actor type, and
  the actors are module-internal so the `ChatEngine` extension can reach them.
  No runtime logic changed; gate behavior (send-id idempotency and tool-output
  validation/reservation from PKRR-006) is preserved exactly.

- **Deduplicated structured-output adapters (PKCR-002)**: The three
  provider-specific adapter types `OpenAICompatibleStructuredOutputAdapter`,
  `OllamaStructuredOutputAdapter`, and `AnthropicStructuredOutputAdapter` have
  been removed. OpenAI-compatible and Ollama providers now register the shared
  `PromptAugmentedJSONSchemaAdapter` (prompt augmentation + native
  `json_schema` response format); Anthropic now registers
  `DefaultStructuredOutputAdapter` (synthetic-tool fallback). The
  `.jsonObject` case is handled uniformly via a `jsonObjectRequest` helper in
  the `StructuredOutputAdapter` protocol extension, eliminating five copies of
  identical code. Downstream consumers referencing the deleted types by name
  should switch to `PromptAugmentedJSONSchemaAdapter` or
  `DefaultStructuredOutputAdapter`.

## [3.2.0] - 2026-07-29

### Added

- **Terminal sidecar commit policy (SDC-10)**: `ChatRunRequest` accepts
  `SidecarCommitPolicy` (default `.everyRoundTrip`). Sidecar completion events now carry a
  Codable `SidecarCompletion` with a stable `TurnIdentity`; `.terminalRoundTrip` buffers
  intermediate results and emits exactly one identified completion only after normal logical-send
  completion. Consumers switching on `sidecarsCompleted` should use `completion.results` and
  key durable persistence by `completion.identity`. Sidecars remain excluded from conversation
  history.

- **CI verification matrix (PKRR-025)**: CI now gates minimum and current pinned Linux
  toolchains separately, runs the full macOS verification gate including docs snippets,
  examples, products, and tests, and compiles/tests iOS library products on an iOS Simulator.
  macOS coverage and platform test logs/results are published as workflow artifacts; Linux
  native bridge exclusions and the iOS command-line example exclusion are explicit.

- **Durable timeline deletion and explicit eviction API (PKRR-023)**: `TimelineManager`
  now distinguishes memory-only eviction from permanent deletion. The former
  `deleteTimeline(id:)` was an in-memory eviction that did not cancel active work (before
  PKRR-002) or touch persistence, yet its name suggested durable deletion — callers could
  leak persisted data and active generation work. `evictTimelineFromMemory(id:)` is now the
  canonical memory-only seam (cancels and drains active work via `TimelineTaskRegistry`
  before removing cached state, leaves persistence untouched).
  `deleteTimelinePermanently(id:)` cancels and drains active work, evicts memory, **and**
  deletes the persisted timeline row, messages, and attached workspace records. Each store
  deletion is best-effort: failures are collected as `StoreDegradation` entries on the
  returned `TimelineDeletionResult` (with `isComplete` reflecting whether every store
  succeeded), so a single store failure no longer strands the remaining records. The
  legacy `deleteTimeline(id:)` is retained as a deprecated alias for
  `evictTimelineFromMemory(id:)`.

- **Docs snippet syntax gate (PKRR-027)**: `make verify` (and the new `make verify-doc-snippets`
  target) now runs `Scripts/compile-doc-snippets.sh`, which extracts every ```swift fenced block
  from `docs/` and `swiftc -parse`-checks it. This is a syntax-only guard (it catches malformed
  snippets and establishes the hook for a fuller gate); the canonical construction / run /
  event-handling shapes in `docs/Usage.md` are additionally type-checked as part of
  `PositronicKitExamples` via `make verify-examples`. A full extract-and-typecheck docs gate is
  tracked under PKRR-025.

- **Validated retry and timeout configuration (PKRR-030)**: `RetryPolicy` and
  `ToolTimeoutEnforcer` no longer accept arbitrary numeric values that could create
  immediate loops, excessive sleeps, or `UInt64` conversion traps. New public types
  `RetryConfiguration` and `Timeout` (in `PKUtilities`) validate at construction:
  negative, NaN, infinite, or extreme values fail with typed errors
  (`RetryConfigurationError`, `TimeoutValidationError`) instead of silently producing
  bad behavior. `RetryConfiguration` enforces finite delay ranges, caps server-advertised
  `Retry-After` hints by `maxRetryAfter`, enforces both attempt (`maxRetries`) and
  total-elapsed (`maxTotalElapsedTime`) limits, and supports injectable deterministic
  jitter via `JitterStrategy` for tests. The legacy `RetryPolicy.retry(maxRetries:baseDelay:)`
  signature delegates to `RetryConfiguration` and throws on invalid inputs (existing call
  sites with valid values are unaffected — additive, backward-compatible). Provider
  `Retry-After` parsing now rejects non-finite values (NaN, infinity) as defense-in-depth.
  `ToolTimeoutEnforcer` uses the shared `Timeout` type for overflow-safe nanosecond
  conversion while preserving its existing `ToolError.executionFailed` error surface.

- **Hard token-budget enforcement (PKRR-021)**: token budgeting now returns a verified result that
  never exceeds the available prompt budget, fails typed when mandatory `.keep` sections cannot fit,
  and preserves summarizer failures instead of converting them into dropped sections.

- **Injectable privacy-safe logging (PKRR-013)**: added `LoggingConfiguration` and a default-off
  `LogRedactionPolicy` that hosts can inject through `PositronicKit.Configuration`. Request
  descriptions, malformed tool arguments, tool errors, ANSI escapes, and presentation emoji no
  longer enter default structured logs; error logs carry stable domain, code, and correlation
  metadata.

- **Handler-owned terminal color for `ANSIColors` (PKRR-024)**: `ANSIColors.colorize(_:color:)`
  always emitted escape sequences with no TTY detection, so any caller that routed its output
  into a `Logger`/JSON/file/OSLog/telemetry sink polluted the record with escape bytes and
  presentation emoji. Added `ANSIColors.colorize(_:color:enabled:)` (pass the owning handler's
  TTY verdict explicitly; `enabled: false` yields plain text for structured sinks) and
  `ANSIColors.strip(_:)`, the single source of truth for the CSI escape grammar now shared with
  `LogRedactionPolicy.sanitize(_:)`. The public legacy `colorize(_:color:)` is retained for
  downstream terminal consumers (PKV3-007); log message construction must use the metadata path
  (`LogKeys`) plus `sanitizeStructured`, never embedded color.

- **Turn degradation policy and diagnostics (PKRR-022)**: required context, agent, and workspace
  preparation failures now abort before provider generation by default (`failRequired`). Hosts may
  select `continueWithWarnings`; downgraded failures are carried as structured `TurnDiagnostic`
  metadata on the initial `generationContext` event, including stable error identity and operation
  details. Origin lookup remains optional and is observable through the same metadata.

- **Structured one-shot generation results (PKRR-019)**: One-shot streaming now
  applies the same idle-timeout and cancellation semantics as timeline chat,
  accepts per-call generation parameters, and exposes `OneShotResult` with
  content, usage, model, response ID, and finish metadata.

- **Recoverable prompt compression and journal validation (PKRR-020)**: duplicate section IDs and
  duplicate compression-plan IDs now throw typed errors instead of terminating the host. Token
  budget compression and runtime prompt-history recording are throwing validation boundaries, and
  a missing prompt diff fails only the affected chat turn with diagnostic state.

- **Opt-in diagnostic snapshots (PKRR-012)**: successful-turn response metadata no longer
  carries prompt, memory, response, reasoning, or tool snapshots by default. Hosts can explicitly
  select `redacted` or `full` snapshots with a byte limit; secret-like values are masked and large
  content is truncated before encoding. Existing `turnSnapshotData` remains additive-compatible.

- **Causal error chain traversal for `ErrorIdentity` (PKRR-014)**: A new
  `CausalError` protocol in `PKShared` enables `ChatEvent.ErrorIdentity.extracting(from:)`
  to traverse wrapper errors (e.g. `PipelineError.stageFailed`,
  `.cleanupFailed`, `.compoundFailure`) and extract the root `PKError`'s domain/code/
  `isBlocked` instead of collapsing to the generic pipeline code 4001. `PipelineError`
  conforms with `usesOwnIdentityAsFallback = false` (its stage-failure code is
  orchestration context, not the root cause); `LLMStreamError` conforms with the default
  `true` (its identity IS the useful classification for the foreign errors it wraps).
  Provider HTTP errors (e.g. a 429) and blocked tool errors now retain their structured
  identity through pipeline wrapping, so consumers never need message substring matching
  for supported errors.

- **Distinct terminal events for max-turn exhaustion and deferred external tool work
  (PKRR-011)**: `ChatEvent.CompletionEvent` gains two new cases — `.maxTurnsReached` and
  `.deferredForExternalTool` — so consumers can reliably distinguish these outcomes from
  normal completion by a single terminal event. Previously, max-turn exhaustion only logged
  and finished the stream (looking identical to a silent success), and deferred external tool
  work finished with no terminal event at all. Every execution path through `ChatEngine` now
  emits exactly one path-specific terminal event before the stream closes:
  `.generationCompleted` (normal completion), `.maxTurnsReached` (turn budget exhausted),
  `.deferredForExternalTool` (host-side tool execution), `.generationCancelled` (direct
  cancellation), or a thrown error (failure). New factory shortcuts
  `ChatEvent.maxTurnsReached()` and `ChatEvent.deferredForExternalTool()` are provided.

- **Operational readiness split from configuration validity (PKRR-018)**:
  `LLMService` gains a public `isReady` property that is `true` only when the configuration
  is valid **and** a primary client is resolved, guaranteeing a primary send can start.
  `isConfigured` continues to report configuration validity only (backward compatible);
  its doc comment now states this explicitly. `getHealthDetails()` adds a `readiness`
  diagnostic that distinguishes "invalid configuration" from "no client resolved for
  provider …; no client factory registered" from "ready". A new `LLMServiceError.clientNotResolved(provider:)`
  case (error code 1008) is thrown by `sendMessage`/`chatStream` (defense-in-depth) when the
  configuration is valid but no client could be created, instead of the generic
  `.notConfigured`. Previously a valid configuration with no registered client factory
  reported `isConfigured == true` while sends failed later with `.notConfigured`.

### Deprecated

- **`TimelineManager.deleteTimeline(id:)` is deprecated (PKRR-023)**: the name suggested
  durable deletion but the method only evicts in-memory state (it neither removed persisted
  records nor, before PKRR-002, guaranteed active-work drainage). It is retained as a
  deprecated alias for `evictTimelineFromMemory(id:)`. Use `evictTimelineFromMemory(id:)`
  for memory-only eviction, or `deleteTimelinePermanently(id:)` to also remove persisted
  timeline, message, and workspace-attachment records.

- **`.meta(.generationCompleted)` and `.completion(.streamCompleted)` are deprecated
  (PKRR-011)**: both cases were defined but never emitted in production (definition/docs-only
  orphans). They are now marked `@available(*, deprecated)` and retained only for `Codable`
  backward compatibility. Consumers should switch on `.completion(.generationCompleted)` for
  terminal completion metadata and on the new `.maxTurnsReached` / `.deferredForExternalTool`
  cases for the corresponding terminal states.

### Fixed

- **Usage guide snippets compile against the current API (PKRR-027)**:
  `docs/Usage.md` examples were updated to match the current grouped `Configuration` API and
  `ChatEvent` vocabulary. The "Simplified Initialization" and "Full Initialization" snippets now
  use `PositronicKit(languageModel:)` and `PositronicKit(configuration:)` instead of the removed
  `PositronicKit(openAIKey:)` / `PositronicKit(ollamaModel:)` / `PositronicKit(llmService:persistence:…)`
  shapes; the "Running a Chat Stream", "Enabling Prompt Assembly Logs", and "Handling Tool
  Outputs" snippets now call `chat.run(ChatRunRequest(…))` instead of the removed
  `run(timelineId:message:…)` overload; and the event switch is exhaustive over the current
  cases (`.delta(.reasoning)`, the PKRR-011 terminal events, `ErrorIdentity.isBlocked`), with the
  deprecated `.meta(.generationCompleted)` / `.completion(.streamCompleted)` covered by `default`
  rather than documented as active. The canonical event-handling shape is now compiled as
  `PositronicKitUsageExamples.consumeChatEventStream(_:)` so `make verify-examples` catches drift.

- **`LLMService` no longer reports configured while unable to send (PKRR-018)**:
  A valid configuration with no registered client factory previously set `isConfigured == true`
  while `sendMessage`/`chatStream` failed later with `.notConfigured`, so preflight
  configuration checks passed and the request failed at dispatch. The new `isReady` property
  (valid configuration **and** a resolved primary client) is the correct preflight gate, and
  `getHealthDetails()` now explains whether the issue is invalid settings or a missing client
  factory. The defense-in-depth guards now throw the more specific
  `LLMServiceError.clientNotResolved(provider:)` when the configuration is valid but no client
  exists.

- **Timeline creation and workspace attachment no longer leave partial state (PKRR-007)**:
  `createTimeline` now persists the timeline record **first**, before creating directories,
  notes, or workspace rows. If any subsequent step fails, the timeline record and any
  partially created state are rolled back (directory removed, timeline deleted) before
  rethrowing. Previously, directory creation, notes, workspace save, and in-memory caching
  all happened before the final timeline save — so a store failure could leak orphan
  directories, workspace rows, and cached managers. `attachWorkspace` now validates the
  workspace exists in the store **before** persisting the attachment. If validation fails
  (workspace not found or store error), the timeline is not mutated. Previously, the
  attachment was persisted first and workspace resolution failure was silently swallowed,
  leaving a dangling workspace ID in the timeline that was not usable at runtime.

- **Tool terminal status is emitted only after the result is durable (PKRR-016)**:
  `ToolRouter` now persists the tool message to the message store **before** yielding the
  terminal `.success` or `.failed` event. Previously the event was yielded first, so a
  consumer could observe success and then lose the result when `saveMessage` threw —
  leaving conversation history inconsistent with the emitted status and making retries
  unsafe. If persistence fails, the router emits a `.persistenceFailed` terminal event
  instead of `.success`/`.failed`, so a store failure never produces a terminal success.

- **Turn input persistence deferred until preparation succeeds (PKRR-006)**:
  `prepareSession` now validates history, gathers context, resolves workspaces, and assembles
  the prompt **before** persisting user input or tool outputs. If any preparation step throws,
  no new messages are persisted, preventing orphan inputs on retry. The `sendId` is used as an
  in-memory idempotency key: a second call with the same `sendId` throws
  `ChatEngineError.duplicateSendId` (error code 9006) while the first is in progress or has
  completed. On failure the `sendId` is released so the caller may retry. Tool-output batches
  are resumable — already-persisted outputs are skipped on retry, so a partial batch can be
  completed without duplication. The `ExternalToolOutputSubmissionGate` is split into
  `validate` (reserve call IDs, no persistence) and `commit` (persist, skipping
  already-present outputs) phases.

- **Pipeline cancellation no longer reported as success (PKRR-009)**: `runPrimaryStages`
  now returns `CancellationError()` when `Task.isCancelled` is detected between stages
  or after the final stage, instead of breaking the loop and returning `nil` (success).
  Cleanup failures are no longer silently dropped when a primary error exists — they are
  collected and returned as `PipelineError.compoundFailure(primary:cleanupFailures:)`
  (error code 4003) so both primary and cleanup failures are observable without log
  scraping. Cleanup always runs, even after cancellation.

- **Linux provider streams now deliver lines incrementally (PKRR-010)**:
  `URLSessionProviderHTTPTransport.lines(for:)` on Linux previously used
  `URLSession.data(for:)`, which buffered the entire HTTP response before splitting lines.
  This caused first-token latency, unbounded memory on large responses, ineffective
  cancellation, and idle-watchdog timeouts on steady streams. The Linux path now uses a
  `URLSessionDataDelegate` that yields complete lines as data chunks arrive, matching the
  incremental streaming behaviour of the Apple path (`URLSession.bytes(for:)`). A
  cross-platform streaming conformance suite in `PKUtilitiesTests` verifies first-chunk
  delivery before response completion, prompt cancellation, bounded buffering on large
  streams, line reassembly across chunked TCP writes, and connection-error propagation.

### Added

- **`FailingWorkspaceStore` enhancements (PKRR-007)**: `FailingWorkspaceStore` now supports
  `saveFails` (throws on `saveWorkspace`) and a mutable `fetchFails` property (toggleable at
  runtime) with `saveAttemptCount`/`workspaces` accessors, enabling lifecycle fault-injection
  tests for `createTimeline` and `attachWorkspace` rollback paths.

- **`ToolExecutionStatus.persistenceFailed(reference:error:)` (PKRR-016)**: a new terminal
  status case emitted when the tool executed (successfully or with an error) but
  `messageStore.saveMessage` threw. Distinct from `.success` and `.failed` — a consumer
  that observes `.persistenceFailed` knows the result is not durable and a retry may be
  needed.

- **`ToolError.invalidWorkspaceID(String)` (PKRR-015)**: a new typed `ToolError` case
  (error code `213`) thrown when the `workspaceID` argument is present but not a valid
  UUID string. The associated value is the malformed input as received. Includes
  `userFriendlyMessage` and `remediation` guiding the caller to supply a valid UUID or
  omit the argument for automatic routing.

- **`TimelineError` taxonomy expansion (PKRR-008)**: adds `corrupt(String)` (error code
  6003), `permissionDenied` (6004), and `invalidState(String)` (6005) to the existing
  `timelineNotFound` (6001) and `unavailable` (6002). Each case provides
  `userFriendlyMessage` and targeted `remediation` guidance. `TimelineError` now conforms
  to `Equatable`.

- **`StoreDegradation` + `WorkspaceQueryResult` types (PKRR-008)**: `StoreDegradation`
  captures a best-effort failure with stable error identity (`ChatEvent.ErrorIdentity`),
  operation name, entity ID, and user-friendly message. `WorkspaceQueryResult` is the
  return type of `getWorkspaces(for:)`, carrying the primary/attached workspaces alongside
  any `degradations` encountered during individual workspace fetches.

- **`FailingWorkspaceStore` + `FailingToolPersistence` test doubles (PKRR-008)**: new
  `PKTestSupport` mocks that throw on `fetchWorkspace` and `fetchToolSource` respectively,
  with attempt counters for assertion. Join the existing `FailingTimelinePersistence` and
  `FailingMessageStore` for comprehensive store-failure test coverage.

- **`ToolSideEffects` enum + `Tool.sideEffects` property (PKRR-004)**: a new public enum on
  `PKShared` (`ToolSideEffects.none` / `.mutating` / `.externalProcess`) declares the
  side-effect class of a tool. The `Tool` protocol gains a `var sideEffects: ToolSideEffects
  { get }` requirement with a default implementation returning `.mutating` — the conservative
  assumption for tools that do not declare themselves side-effect-free. `AnyTool` forwards the
  declared value. This is an additive, backward-compatible public API change: existing tool
  conformers in `PositronicKit`, `Monad`, `Shuttle`, `Yakamoz`, and `LandGo` inherit the
  `.mutating` default with no source changes.

- **`ToolError.timedOutButMayStillBeRunning(timeout:)` (PKRR-004)**: a new typed
  `ToolError` case (error code `212`) distinct from `.executionFailed`. It is thrown by
  `ToolTimeoutEnforcer` when a `.mutating` or `.externalProcess` tool is abandoned after a
  wall-clock timeout — the tool may still be executing out-of-band and retrying may duplicate
  side effects. The associated value is the `TimeInterval` timeout, not a string. The
  `userFriendlyMessage` and `remediation` surface the may-still-be-running condition and the
  retry hazard to the model/UI/operator.

- **`ToolError.timeoutDescription(_:)` (PKRR-004)**: a public overflow-safe formatter for
  timeout values in human-readable messages. Shared by the clean-timeout and
  may-still-be-running terminal states so the wording stays consistent. Overflow-safe: a
  finite whole number larger than `Int.max` renders via the `Double` fallback rather than
  trapping on `Int` conversion.

- **`ProviderConfiguration.contextWindowTokens` (PKRR-001)**: a new public property on
  `PKShared.ProviderConfiguration` declaring the model's full context-window size in tokens.
  Per-provider defaults are populated by ``defaultFor(_:)`` (e.g. 128_000 for OpenAI,
  200_000 for Anthropic, 8_192 for Ollama/OpenAI-compatible). Hosts override it to steer
  prompt budgeting per model. Codable round-trips and decoding of older configs that omit
  the key fall back to 8_192. Additive, backward-compatible public API change.

- **`TokenBudgetError` + validated `TokenBudget(contextWindow:outputReserve:)` (PKRR-001)**:
  a new `PKPrompt` error enum conforming to `PKError` (domain `com.positronickit.core.prompt`,
  codes 1101–1103) and a throwing initializer that rejects non-positive context windows,
  negative output reserves, and reserves that consume the entire context window. Also adds
  a public `TokenBudget.availableTokens` computed property (`maxTokens - reserveForResponse`).
  The existing non-throwing `init(maxTokens:reserveForResponse:)`/`init(maxTokens:)`
  initializers remain for direct/test use.

- **`ChatEngine.makeTokenBudget(contextWindowTokens:maxOutputTokens:)` (PKRR-001)**: an
  internal static helper that derives a validated `TokenBudget` from the model's context
  window and the per-turn response output limit. The prompt budget is
  `contextWindowTokens − (maxOutputTokens ?? defaultOutputReserve) − providerOverhead`.

- **`DurabilityAware` protocol + `isDurable` on store protocols (PKRR-017)**: a new public
  protocol `DurabilityAware` (with default `isDurable == false`) is now the parent of all
  seven persistence store protocols (`MessageStoreProtocol`, `TimelinePersistenceProtocol`,
  `WorkspaceStore`, `MemoryStoreProtocol`, `ToolPersistenceProtocol`,
  `AgentInstanceStoreProtocol`, `RequestOriginStoreProtocol`). Durable adapters (GRDB,
  SwiftData) override to `true`. A single parent default — rather than per-protocol defaults
  — avoids ambiguity for types that conform to multiple store protocols. Additive,
  backward-compatible: existing conformers inherit `false` with no source changes.

- **`DurabilityReport` + `PersistenceConfiguration.validateDurability()` (PKRR-017)**: a new
  public `DurabilityReport` struct (with `StoreDurability.durable` / `.ephemeral` enum)
  classifies each of the seven stores. `PersistenceConfiguration.validateDurability()` returns
  the report; `report.isMixed` is `true` when some stores are durable and others ephemeral;
  `report.ephemeralStoreNames` lists the specific ephemeral stores; `report.mixedDurabilityWarning`
  returns the full warning message or `nil`.

- **`PersistenceConfiguration.fullyPersistent(stores:)` factory (PKRR-017)**: a static factory
  that requires all seven stores as non-optional parameters — the explicit "full durability"
  entry point for production hosts. The existing optional-store initializer remains for
  mixed/ephemeral setups.

- **Mixed-durability startup warning (PKRR-017)**: `PositronicKit.init(configuration:)` now
  calls `validateDurability()` during construction. If the configuration is mixed (some
  `.durable`, some `.ephemeral`), a `.warning` is logged naming the specific ephemeral stores
  and noting that durable stores may reference entities missing after restart. The warning is
  non-fatal; all-ephemeral and all-durable configurations do not trigger it.

### Changed

- **Makefile no longer performs Swift package discovery at parse time (PKRR-026)**:
  `swift package describe` used to run while parsing almost every target, so even
  `make help` failed before execution when Swift or dependency resolution was
  unavailable. Product discovery now runs lazily inside the `verify-products` recipe
  (per-product builds still work via the `verify-product-<Name>` pattern rule), so
  `make help`, `make clean`, and `make doctor` no longer require Swift. Added a
  `make doctor` preflight that reports Swift, Rust, the C/C++ toolchain, pkg-config,
  OpenSSL headers, curl, shasum, a container runtime, the pinned MiniLM model
  assets, and the host platform, with actionable hints for anything missing. The
  `linux-image`/`linux-build`/`linux-test` targets now fail with one clear message
  when no container runtime (`CONTAINER_RUNTIME`) is configured, instead of a
  cryptic shell error from an empty runtime.

- **Store outages no longer collapse into not-found or silent nil (PKRR-008)**: all `try?`
  patterns in `TimelineManager+Lifecycle`, `TimelineManager+Attachments`, and
  `TimelineManager` that turned persistence failures into `timelineNotFound` or `nil`
  have been replaced with typed error propagation. `updateTimelineTitle`,
  `attachWorkspace`, `detachWorkspace`, and `getWorkspaces` now distinguish
  `TimelineError.timelineNotFound` (entity genuinely absent) from
  `TimelineError.unavailable` (store threw). `getToolSource` is now `throws` instead of
  returning `nil` on store failure. Each error site logs stable error identity
  (`errorDomain` + `errorCode`) and operation metadata (timeline ID, operation name)
  via `ErrorKit.userFriendlyMessage(for:)`.

- **`TimelineError` taxonomy expanded (PKRR-008)**: adds `corrupt(String)` (6003),
  `permissionDenied` (6004), and `invalidState(String)` (6005) alongside the existing
  `timelineNotFound` (6001) and `unavailable` (6002). All cases include `userFriendlyMessage`
  and targeted `remediation` guidance. `TimelineError` now conforms to `Equatable`.

- **`getWorkspaces(for:)` returns `WorkspaceQueryResult` instead of an optional tuple
  (PKRR-008)**: the method is now `async throws -> WorkspaceQueryResult`. A missing timeline
  throws `TimelineError.timelineNotFound`; a store outage throws `TimelineError.unavailable`.
  Individual workspace fetch failures that were previously silently dropped are now collected
  as `[StoreDegradation]` entries on the result, carrying stable error identity and operation
  metadata. **Public API change:** callers that used `await getWorkspaces(for:)` must now
  `try await` and access `.primary`/`.attached` directly (no optional unwrap). The
  `ToolRouter` catches `timelineNotFound` to preserve its "tool not found" behavior; store
  outages propagate as typed errors.

- **`getToolSource(toolId:for:)` is now `throws` (PKRR-008)**: a store failure throws
  `TimelineError.unavailable` instead of returning `nil`. A genuinely unknown tool still
  returns `nil` (not-found is not an error). Callers that used `try?` or `await` without
  `try` must now handle the error.

- **Best-effort workspace resolution now logs degradations (PKRR-008)**:
  `setupTimelineComponents` and `attachWorkspace`'s workspace-registration path catch and
  log workspace resolver failures with stable error identity and operation metadata, rather
  than silently dropping them via `try?`. The timeline remains usable (degraded) when an
  attached workspace can't be resolved.

- **`ToolTimeoutEnforcer` now reports side-effect-aware terminal states (PKRR-004)**: on
  timeout, tools that declare `sideEffects == .none` preserve the current fast-abandon clean
  timeout (`ToolError.executionFailed` with a "timed out" message) — this is the only case
  where the runtime claims the operation stopped. Tools that declare `.mutating` or
  `.externalProcess` (and tools that rely on the `.mutating` default) now throw
  `ToolError.timedOutButMayStillBeRunning` so the caller is informed that the tool may still
  be executing and retrying may duplicate side effects. The enforcer still cancels best-effort
  and returns promptly; it does NOT block waiting for the uncooperative tool — only the
  reported status changes. Callers that pattern-matched on `.executionFailed` with a
  "timed out" substring for timeout classification should add an arm for
  `.timedOutButMayStillBeRunning`.

- **`openTimeline(_:)` now requires an existing timeline (PKRR-005).** `PositronicKit.openTimeline(_:)`
  opens an existing timeline only — a missing (never-persisted) ID is an error, not a silent creation.
  Sending to a missing timeline via `TimelineDriver.send(_:)` or `PositronicKit.run(_:)` now throws
  `TimelineError.timelineNotFound` **before** any user input is persisted. Previously, hydration errors
  were logged and the turn proceeded unhydrated, which could persist messages under an ID with no
  backing timeline/workspace record. Store-outage during hydration is distinguishable from not-found:
  it throws `TimelineError.unavailable`. The explicit creation path remains
  `TimelineManager.createTimeline(title:)`; no auto-creation on first send was added.

- **Prompt compression budget is now derived from the model context window, not the response
  output limit (PKRR-001)**: `ChatEngine+TurnPreparation` no longer feeds
  `GenerationParameters.maxTokens` (the response output limit) into `TokenBudget(maxTokens:)`
  as the whole context-window budget. Instead it derives the budget from
  `ProviderConfiguration.contextWindowTokens` minus the output reserve and a small provider
  overhead via `ChatEngine.makeTokenBudget`. A small output limit (e.g. 512 tokens) no longer
  destructively compresses a prompt that fits the model's context window. The budget is now
  always applied (previously it was optional and only set when `maxTokens` was non-nil); when
  `maxTokens` is nil a conservative default reserve (4_096) is used.

### Fixed

- **Malformed explicit `workspaceID` no longer silently falls back to auto-routing
  (PKRR-015)**: `ToolRouter.resolveWorkspace` now treats the presence of the `workspaceID`
  argument as explicit routing intent. If the value is not a string or does not parse as a
  UUID, `ToolError.invalidWorkspaceID` is thrown before tool execution. Previously, a
  malformed value caused the `if let` to fail silently and fall through to
  `findWorkspaceForTool`, potentially executing the tool against a different workspace than
  the caller intended. A valid UUID that does not match any candidate workspace continues
  to throw `ToolError.workspaceNotFound` (unchanged from YAK-33).

- **Persistence and resolution errors no longer collapse into not-found or empty results
  (PKRR-008)**: `try?` patterns in `TimelineManager+Lifecycle`,
  `TimelineManager+Attachments`, and `TimelineManager` turned store outages into
  `timelineNotFound`, `nil`, or skipped entries — making outages and corruption
  indistinguishable from missing data. `updateTimelineTitle`, `attachWorkspace`,
  `detachWorkspace`, `getWorkspaces`, and `getToolSource` now propagate typed
  `TimelineError`s. Best-effort paths (`setupTimelineComponents` workspace resolution,
  individual workspace fetches in `getWorkspaces`) log degradations with stable error
  identity and return `StoreDegradation` diagnostics instead of silently dropping failures.
  Operators retain causal information; the runtime no longer routes tools incorrectly or
  tells users an entity does not exist when the store is merely unavailable.

- **Timeline cancellation API is now wired to the active chat task (PKRR-002)**:
  `TimelineDriver.cancel()` delegated to `TimelineManager.cancelGeneration(for:)`, but the
  manager only cancelled tasks previously stored by `registerTask` — and `ChatEngine` created
  its own stream-driving task without ever registering it. The documented cancellation path
  was a silent no-op while provider streaming, tools, persistence, and plugins continued. A
  new send-scoped `TimelineTaskRegistry` (owned by `TimelineManager`) now tracks the exact task
  that drives each stream, keyed by `(timelineID, sendID)`. `ChatEngine.execute(...)` registers
  its task before returning the stream and removes it on the terminal path (`defer`-equivalent).
  `TimelineDriver.cancel()` cancels the active task via the registry; eviction/deletion cancels
  and awaits bounded cleanup. Send-scoped handles ensure a stale send's terminal cleanup or
  cancellation cannot evict or terminate a newer send. **Public API change:**
  `TimelineManager.registerTask(_:for:)` is now `registerTask(_:sendID:for:)` (async, adds
  `sendID` parameter); `TimelineManager.cancelGeneration(for:)` is now async; new
  `cancelGeneration(sendID:for:)` provides send-scoped cancellation; new
  `removeTask(sendID:for:)` and `cancelActiveTaskAndAwait(for:)` support terminal-path cleanup
  and eviction. Downstream consumers (`Monad`, `Shuttle`, `Yakamoz`) that call
  `cancelGeneration(for:)` already `await` it; `registerTask` had no production callers.

- **A failed or cancelled turn is now terminal (PKRR-003)**: the turn loop previously treated
  cancellation and error completion as a normal `.stop`, which the outer loop read as successful
  completion and used to run `ChatTurnFollowUpPolicy`. After consumers received a terminal
  failure/cancellation, the runtime could still invoke `ChatTurnPlugin.afterTurn`, append
  messages, build follow-up prompt snapshots, and start another LLM turn — creating hidden cost,
  state mutation after terminal delivery, and hard-to-reproduce races. The binary loop signal
  (`.stop`/`.continueWith`) is replaced with typed terminal outcomes (`.completed`,
  `.continueWith`, `.failed`, `.cancelled`); only `.completed` runs plugin follow-up policy, and
  the terminal outcomes return immediately without any post-terminal activity. Stream
  finalization for the terminal paths remains in `runOneTurn` (where the partial turn is
  persisted and the continuation finished), so exactly one terminal stream state is emitted per
  turn. Internal change to `ChatEngine`'s turn loop — no public API impact.

- **`ToolTimeoutEnforcer` timeout-value validation (PKRR-004, relates to PKRR-030)**: the
  enforcer now rejects negative, infinite, or NaN timeouts as a clean `executionFailed`
  before the race starts, so a tool never runs against an invalid wall-clock bound. The
  nanosecond conversion is overflow-safe: a finite timeout whose `UInt64` nanosecond product
  would overflow is clamped to `UInt64.max` rather than trapping.

- **Response `maxTokens` is no longer used as the prompt context-window budget (PKRR-001)**:
  `GenerationParameters.maxTokens` (the response output limit) was fed directly into
  `TokenBudget(maxTokens:)` as the whole prompt/context-window budget, so a small output limit
  (e.g. 512 tokens) would compress the entire prompt toward roughly 256 tokens even when the
  provider had a much larger context window. Zero or very small output limits could produce a
  negative prompt budget. The budget is now derived from the model's context window
  (`ProviderConfiguration.contextWindowTokens`) minus the output reserve and provider overhead,
  and invalid capacities are rejected with a typed `TokenBudgetError`.

## [3.1.0] - 2026-07-20

Stable release of the 3.1.0 line. Includes all changes from `3.1.0-beta.1` and `3.1.0-beta.2`
(iOS platform support, `PromptJournal` hydration state, and the structured-output one-shot
`complete(_:structuredOutput:)`) plus the fixes below.

### Added

- **Two new `LLMServiceError` cases**: `.emptyResponse(provider:)` (error code `1006`) and
  `.unexpectedResponse(provider:reason:)` (error code `1007`). These give the timeline-free one-shot
  paths (`PositronicKit.complete(_:)` and the structured-output `complete(_:structuredOutput:)`) typed
  errors for empty/non-viable provider output instead of silently returning an empty string. Additive
  enum cases — existing `switch` sites that are exhaustive over the previous cases need a new arm only if
  they handle errors generically.

### Fixed

- **Structured-output adapter registration (regression)**: restored `StructuredOutputAdapterRegistry.register(...)`
  calls in `PKOpenAIProvider.makeClient`, `PKAnthropicProvider.makeClient`, and `PKOllamaProvider.makeClient`
  that were lost in `54349bc` ("refactor: make provider adapters leaf targets"). Only `PKOpenRouterProvider`
  had been fixed (`3a57948`); the other three providers silently fell back to `DefaultStructuredOutputAdapter`
  (synthetic tool calls) instead of their dedicated adapters. This caused structured-output failures on
  OpenAI-compatible endpoints (LandGo's "Custom OpenAI" provider) and Ollama, where the synthetic tool
  approach is unsupported by many servers/models.

- **Malformed provider frames now propagate as errors**: the Anthropic, Ollama, and OpenRouter streaming
  clients previously swallowed SSE/NDJSON decode failures (Anthropic logged a warning and returned;
  Ollama logged and skipped the line; OpenRouter logged but did not finish the stream with an error).
  A malformed frame is a stream failure, not a recoverable content omission, so all three now `throw`/
  `continuation.finish(throwing:)` the decode error through the public async API. This restores
  visibility of provider/transport breakage that was previously silently dropped.

### Changed

- **`OpenAICompatibleStructuredOutputAdapter` now uses native `response_format: json_schema`** with prompt
  augmentation, mirroring the Ollama adapter's belt-and-suspenders approach. Previously it used synthetic
  forced tool calls (`emit_structured_response`), which many OpenAI-compatible servers (LM Studio, vLLM,
  llama.cpp) and local models do not support. The adapter now sends the schema as a native
  `response_format` constraint AND augments the prompt with the schema text, maximizing the chance of
  valid JSON output across heterogeneous OpenAI-compatible servers.

- **One-shot APIs now guard against empty output**: `PositronicKit.complete(_:)` and the structured-output
  one-shot path throw `LLMServiceError.emptyResponse(provider:)` when the assembled response is empty
  after trimming whitespace, rather than returning an empty `String`. Errors from the underlying stream
  are now wrapped via `wrapForeignError` so non-`PKError` failures surface with a friendly message.

## [3.1.0-beta.2] - 2026-07-18

### Added

- **Structured-output one-shot `complete(_:structuredOutput:)`**: a `PositronicKit` facade
  extension mirroring the existing timeline-free `complete(_:)`/`stream(_:)` pair, but for
  structured output. Threads a `StructuredOutputRequest` through the same provider-adapter
  path as the full chat pipeline (`StructuredOutputExecution`/`sendStructuredMessage`),
  including synthetic-tool-call rewriting for providers without native JSON-schema support,
  and returns the assembled JSON payload as a `String` decodable via `StructuredOutputDecoder`.

## [3.1.0-beta.1] - 2026-07-17

### Added

- **iOS platform support**: added `.iOS(.v18)` to the package manifest. Core targets
  (`PositronicKit`, `PKPrompt`, `PKShared`) and `PKAnthropicProvider` build for iOS. Native
  MiniLM bridge (`PKFastEmbed`) remains macOS/Linux only via the `MiniLMEmbeddings` trait.
- **`PromptJournal` hydration state**: added the public `PromptJournal.State` Codable/Sendable
  snapshot plus `state` and `init(state:)` APIs for replaying journal observations with identical
  section plans, emission modes, and append-pressure behavior.

## [3.0.0] - 2026-07-15

Stable release of the v3 vocabulary-and-composition batch. Includes all changes from
`3.0.0-beta.1` plus the final consumer-migration blockers and a complete source-migration map.

### Fixed

- **`LLMService` dynamic provider-client swap (PKV3-015)**: replaced the dead `makeClients(with:)`
  stub with an optional `clientFactory` hook on `LLMService`. All `LLMService` initializers accept
  `clientFactory`, and `updateClient(with:)` delegates to it. This unblocks hosts such as
  Monad's `ConfigurationAPIController` that reconfigure the active provider at runtime.
- **`TimelineManager` tool query/mutation gap (PKV3-010 gap)**: added `enabledTools(for:)`,
  `enableTool(id:for:)`, and `disableTool(id:for:)` so hosts can read/toggle timeline tools
  without accessing the internal `TimelineToolRegistry`.

### Changed

- **Linux development container and CI**: added a Dev Container, Docker/Podman `make` targets,
  and a GitHub Actions Linux gate. Hardened container and bind-mount handling for rootless
  Podman and CI environments.

### Added

- **Source migration map** documenting the old v2 API, the v3 replacement, and behavior notes for
  every breaking change in this release.

### Source migration map

| Old API | New API | Notes |
|---------|---------|-------|
| `llmService` parameter/property | `languageModel` | Use `any LanguageModel` as the composition seam for stream/config/utility capabilities. |
| `ExternalLLMProviderRegistry` | removed | Construct provider clients directly; use `PKXProvider.makeClient(configuration:)`. |
| `ProviderFactoryRequest` | removed | Replaced by direct provider client construction. |
| `ToolProviding` | `ToolSource` | `provideTools()` → `tools()`. |
| `ToolProvenance` | `ToolOrigin` | Renamed enum; `AnyTool.provenance` → `AnyTool.origin` (now `let`, captured at erasure). |
| `AnyTool(_:provenance:)` | `AnyTool(_:origin:)` | `origin` defaults to `.global`. |
| `ToolReferenceProviding` | removed | Override `Tool.identity` (default `.known(id: callName)`) instead. |
| `TimelineToolManager` | `TimelineToolRegistry` | Internal tool-registry type renamed. |
| `ToolApprovalGate` | `ToolApprovalPolicy` | `DenyAllToolApprovalGate` → `DenyAllToolApprovalPolicy`; `AllowAllToolApprovalGate` → `AllowAllToolApprovalPolicy`. |
| `ContextManager` | `TurnBriefingBuilder` | Turn-briefing coordinator renamed. |
| `TimelinePromptHistoryRegistry` | `TimelinePromptJournals` | Now internal; `TimelinePromptHistory` value types moved to `TimelinePromptHistoryTypes`. |
| `PromptInspecting` / `TurnInspecting` | `PromptObserving` | `didComposeTurn(_:)` → `didComposePrompt(_:)`; `TurnInspection` → `PromptInspection`; `turnInspector` → `promptObserver`. |
| `Conversation` | `TimelineDriver` | `PositronicKit.newConversation(title:)` / `.conversation(timelineId:)` → `createTimeline(title:)` + `openTimeline(_:)`. |
| `PKObservable.ObservableConversation` | `PKObservable.TimelineController` | `conversation` property → `driver`. |
| `WorkspaceProtocol` | `Workspace` | Workspace role names made explicit. |
| `WorkspaceCreating` | `WorkspaceFactory` | |
| `WorkspacePersistenceProtocol` | `WorkspaceStore` | |
| `AgentWorkspaceService` | `DefaultWorkspaceCatalog` | |
| `WorkspaceManager` | `DefaultWorkspaceResolver` | |
| `WorkspaceManagerProtocol` | `WorkspaceResolver` | |
| `TimelineManager.getTimeline(id:)` | `timeline(id:)` / `touchTimeline(id:)` | Use `timeline(id:)` for a pure lookup; `touchTimeline(id:)` to preserve the old update-on-read behavior. |
| `TimelineManager.getToolManager(for:)` / `workspaceResolver` | no longer public | Use `enabledTools(for:)`, `enableTool(id:for:)`, `disableTool(id:for:)`. |
| `LLMConfiguration` flat init + 18 write-through proxies | `LLMConfiguration(activeProvider:providers:)` | Read the active provider via `activeProviderConfiguration`; mutate `providers[activeProvider]`. |
| `PKShared` filesystem tools, `ANSIColors`, `PathSanitizer`, `RetryPolicy`, `TokenEstimator`, `LogKeys`, `ProviderHTTPTransport` | `PKUtilities` | Add a `PKUtilities` product dependency and import. |
| `Message.think` | `Message.reasoning` | Unified reasoning/thinking vocabulary. |
| `LLMStreamDelta.thinking` | `LLMStreamDelta.reasoning` | |
| `ChatEvent.delta(event:)` | `ChatEvent.delta(DeltaEvent)` | Wrapper cases flattened to match `Result` naming conventions. |
| `ChatEvent.meta(event:)` | `ChatEvent.meta(MetaEvent)` | |
| `ChatEvent.error(event:)` | `ChatEvent.error(ErrorEvent)` | |
| `ChatEvent.completion(event:)` | `ChatEvent.completion(CompletionEvent)` | |
| `ToolExecutionStatus.failure(String)` | `ToolExecutionStatus.executionError(String)` | Eliminates collision with `ToolResult.failure`. |
| `PositronicKit.addPlugin(_:)` | `PositronicKit.addingPlugin(_:)` | Nonmutating participle-form naming. |
| `MemorySavePolicy.preventSimilar(threshold:)` | `MemorySavePolicy.deduplicating(threshold:)` | Case grammar aligned with `.immediate` / `.deferred`. |
| `formatToolsForPrompt(_:)` | `[AnyTool].formattedForPrompt()` | Free function with receiver argument moved to extension. |
| `PositronicKit.sidecarsIfEnabled(_:when:)` | removed | Inline `isEnabled ? sidecars : []`. |
| `ToolOutputParser` | removed | Models must emit provider-native structured tool calls. |
| `PipelineBuilder` / `Collection.assertUniqueIDs()` / `CollectionUniqueIDError` | removed | Assemble pipelines imperatively; use `duplicateIDs(idKeyPath:)` instead. |
| `PKOpenAIEmbeddingService` | removed | Use `LocalEmbeddingService` / `NoOpEmbeddingService`. |
| `PKShared.MessageParser` | removed | `Message.parseResponse(_:)` / `Message.displayContent` now inline the implementations. |
| `OpenAIStructuredOutputAdapter` / `OpenRouterStructuredOutputAdapter` | `PKShared.NativeJSONSchemaStructuredOutputAdapter` | Shared adapter registered by each provider. |
| `AnyTool.init(_:provenance: String?)` | `AnyTool.init(_:provenance: ToolProvenance)` / `AnyTool(_:origin: ToolOrigin)` | String-provenance bridge was already deprecated and is now removed. |
| `PositronicKit.PromptBuildContext` aliases | removed | Use `PromptBuildContext` directly. |
| `AgenticRuntime.workspaceId` / `PositronicKit.agenticRuntime(...workspaceId:)` | removed | Dead passthrough; workspace routing is resolved from timeline attachments. |
| `PKShared.ToolConfiguration` / `PositronicKit.WorkspaceToolError` / `PositronicKit.InMemoryKeyValueStore` | removed | Dead public types with zero consumers. |

## [3.0.0-beta.1] - 2026-07-13

Prerelease of the v3 vocabulary-and-composition batch (PKV3-001–014) for downstream consumer
verification. Not yet a stable release — see `workflow/PositronicKit/tickets/PKV3-006-*.md` for
the remaining consumer-migration and final-release work.

### Fixed

- **`PKTestSupport` restored as a public library product**: `PKHYG-002` (2026-07-12) removed it
  from `products:`, on the premise that "no downstream migration required." That premise was
  wrong — Monad's `MonadServerTests` target (16 files) depends on it as an external product;
  the break only surfaced now because Monad hadn't yet resolved against a tag containing that
  change. The `Tests/PKTestSupport` target itself was never touched by PKHYG-002; this just
  re-adds the one-line product declaration.
- **`TimelineManager` tool query/mutation gap (found auditing PKV3-010 against Monad)**: PKV3-010
  made `getToolManager(for:)` internal, but left no public replacement for reading or toggling a
  timeline's enabled tools — a real host need, not subordinate-manager access. Added
  `enabledTools(for:) async -> [AnyTool]`, `enableTool(id:for:) async -> Bool`, and
  `disableTool(id:for:) async -> Bool`; none expose `TimelineToolRegistry` itself.

### Breaking

- **Direct `LanguageModel` injection (PKV3-001)**: public composition vocabulary renamed from
  `llmService` to `languageModel` (`PositronicKit+Configuration`, and the corresponding facade
  initializer parameters). Added public `LanguageModel` protocol as the composition of
  stream/config/utility capabilities. Deleted `ExternalLLMProviderRegistry` and
  `ProviderFactoryRequest` along with the process-global provider `register()` construction
  paths — hosts select/construct their provider client directly instead. `ProviderHTTPTransport`
  is package-internal (now in `PKUtilities`, see PKV3-009).
- **Tool registration/execution/approval vocabulary (PKV3-004)**: `ToolProviding` → `ToolSource`,
  `provideTools()` → `tools()`, `ToolProvenance` → `ToolOrigin`, `TimelineToolManager` →
  `TimelineToolRegistry`, `ToolApprovalGate` → `ToolApprovalPolicy` (with
  `DenyAllToolApprovalGate`/`AllowAllToolApprovalGate` → `DenyAllToolApprovalPolicy`/
  `AllowAllToolApprovalPolicy`, `toolApprovalGate` → `toolApprovalPolicy`). All conformers, call
  sites, tests, and examples migrated.
- **Explicit `AnyTool` identity (PKV3-012)**: added `Tool.identity: ToolReference` (default
  `.known(id: callName)`) and `AnyTool.identity`/`AnyTool.origin` (origin now `let`, captured
  immutably at erasure). Added `AnyTool.withOrigin(_:)` for origin-stamping copies. Deleted
  `ToolReferenceProviding` and its dynamic-cast fallback.
- **Turn briefing and prompt journal vocabulary (PKV3-005)**: `ContextManager` →
  `TurnBriefingBuilder`, `TimelinePromptHistoryRegistry` → `TimelinePromptJournals` (now
  package-internal), `PromptInspecting` → `PromptObserving` (`promptInspector` →
  `promptObserver`). Added a `TurnBriefing` typealias for `ContextData`.
- **`PKUtilities` split from `PKShared` (PKV3-009)**: new public `PKUtilities` library product
  (depends only on `PKShared`; `PKShared` does not import it). Cross-cutting observability
  (`RetryPolicy`, `ProviderHTTPFailure`/`ProviderHTTPTransport`, `LogKeys`, `LogRedaction`,
  `Logger+Extensions`), async/pipeline helpers (`Pipeline`, `Pipeline+Logging`,
  `CancellableAsyncThrowingStream`, `Collection+UniqueIDs`), `StableHash`, `TokenEstimator`,
  `PathSanitizer`, `LimitedErrorBodyCollector`, `ANSIColors`, and the concrete filesystem tools
  (`ReadFileTool`, `FindFileTool`, `ListDirectoryTool`, `SearchFileContentTool`,
  `SearchFilesTool`, `ChangeDirectoryTool`) moved from `PKShared`/`PositronicKit` into
  `PKUtilities`. Consumers that referenced these types from `PKShared` or `PositronicKit` must
  add a `PKUtilities` dependency and update imports.
- **Provider targets are leaf modules (PKV3-011)**: `LanguageModel` and narrow capability
  protocols relocated to `PKShared`. Every provider target (`PKOpenAIProvider`,
  `PKOpenRouterProvider`, `PKOllamaProvider`, `PKAnthropicProvider`,
  `PKFoundationModelsProvider`) now depends only on `PKShared`/`PKUtilities` plus its vendor
  SDK — zero `import PositronicKit`. `PositronicKit`-side provider-convenience extensions
  removed; hosts construct/inject concrete clients directly (e.g.
  `PKOpenAIProvider.makeClient(configuration:)`).
- **Legacy `LLMConfiguration` compatibility surface removed (PKV3-014)**: deleted the legacy
  flat initializer and its 18 write-through proxy properties (`endpoint`, `apiKey`, `modelName`,
  `utilityModel`, `fastModel`, `toolFormat`, `timeoutInterval`, `maxRetries`, `temperature`,
  `maxTokens`, `topP`, `frequencyPenalty`, `presencePenalty`, `seed`, `applicationURL`,
  `applicationTitle`, `generationParameters`, `provider`). Added
  `LLMConfiguration.activeProviderConfiguration: ProviderConfiguration` as the canonical
  read-only replacement — it resolves `providers[activeProvider]`, falling back to
  `ProviderConfiguration.defaultFor(activeProvider)` if absent. Construct/mutate
  `providers[activeProvider]` directly to write. Migrated all 4 provider adapters
  (`PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider`, `PKAnthropicProvider`) and
  every in-package call site. Note: `activeProviderConfiguration`'s per-provider defaults differ
  from the old flat init's universal 60s `timeoutInterval` default — Ollama's canonical default
  is 120s (local models can be slower), which the flat init previously masked.
- **Compatibility surface removed (PKV3-007, partial)**: deleted the deprecated
  `CompactionThresholds` typealias (use `PromptJournalCompactionThresholds`), the deprecated
  `EmptySection` typealias (use `EmptyPrompt`), and `TimelineManager.getTimeline(id:)` (use
  `timeline(id:)` for a pure lookup, or `touchTimeline(id:)` + `timeline(id:)` to preserve the
  old touch-on-read behavior — Monad's `ChatAPIController`/`TimelineAPIController` were migrated
  to that pattern). `StreamingParser` is no longer a public type (no external consumer found).
  `VectorMath` and `ANSIColors` remain public — both have a demonstrated downstream consumer
  (Monad's `MemoryRepository` and `WebSocketConnectionManager` respectively). **Deferred to a
  follow-up**: the legacy flat `LLMConfiguration` initializer and its 18 write-through proxy
  properties — used by all 4 provider adapters and many tests, too large to fold into this pass
  without its own migration plan.
- **`TimelineManager` narrowed to lifecycle operations (PKV3-010)**: `workspaceResolver` and
  `getToolManager(for:)` are no longer public. Hosts inject a `WorkspaceResolver` at
  construction rather than reading it back off `TimelineManager`; normal tool-execution flows go
  through `TimelineDriver`/`ChatEngine`, not direct `TimelineToolRegistry` access.
- **`TimelineDriver` replaces `Conversation` (PKV3-003)**: `Conversation` and its vending
  methods (`PositronicKit.newConversation(title:)`, `PositronicKit.conversation(timelineId:)`)
  are deleted. `PositronicKit.openTimeline(_:)` returns a new `TimelineDriver` — a lightweight,
  stable handle with `timelineID`, `send(_:)`, and `cancel()`. Unlike `Conversation`,
  `TimelineDriver` holds no mutable turn state, performs no persistence lookup on construction,
  and does not expose the underlying `TimelineManager`; opening one is pure value
  construction, with persistence happening lazily the first time `send(_:)` executes a turn,
  exactly as before. To create and open a brand-new persisted timeline, call
  `timelineManager.createTimeline(title:)` and then `kit.openTimeline(timeline.id)`.
  `PKObservable.ObservableConversation` is renamed to `PKObservable.TimelineController`
  (its `conversation` property is renamed to `driver`); its superseding-send behavior is
  unchanged.


- **Workspace vocabulary rename + injectable `WorkspaceResolver` (PKV3-002)**: renamed the
  overlapping workspace protocol/service names to make each role explicit —
  `WorkspaceProtocol` → `Workspace`, `WorkspaceCreating` → `WorkspaceFactory`,
  `WorkspacePersistenceProtocol` → `WorkspaceStore`, the `AgentWorkspaceServiceProtocol`
  protocol → `WorkspaceCatalog`, its concrete `AgentWorkspaceService` implementation →
  `DefaultWorkspaceCatalog`, the `WorkspaceManagerProtocol` protocol → `WorkspaceResolver`, and
  its concrete `WorkspaceManager` implementation → `DefaultWorkspaceResolver`.
  `TimelineManager` now exposes `workspaceResolver: any WorkspaceResolver` (renamed from
  `workspaceManager`) and gains a designated initializer that accepts `resolver: any
  WorkspaceResolver` directly, so hosts can inject a fully custom resolver without
  `TimelineManager` composing `DefaultWorkspaceCatalog`/`DefaultWorkspaceResolver` internally.
  The bundled default catalog/factory/resolver composition now lives in the new
  `WorkspaceResolverFactory.makeDefault(workspaceRoot:workspaceStore:workspaceCreator:)`, used
  by both the `workspaceCreator:`-based `TimelineManager` convenience initializer and the
  `PositronicKit` facade, so default behavior for existing callers is unchanged. All old public
  names (`WorkspaceProtocol`, `WorkspaceCreating`, `WorkspacePersistenceProtocol`,
  `AgentWorkspaceService`, `WorkspaceManager`, and their `*Protocol` variants) are gone.

### Added

- **Provider capability observability (PKV3-008)**: structured, payload-safe warnings (provider,
  model, option category, reason, timeline ID, turn index — never prompt/tool-argument/response
  content) are now emitted once per turn when a provider ignores or coerces
  tools/tool-choice/response-format/generation-parameters. Published
  `docs/ProviderCapabilityMatrix.md` documenting per-provider variance.

### Confirmed unchanged

- **Persistence seam audit (PKV3-013)**: both `AgentInstanceStoreProtocol` and
  `RequestOriginStoreProtocol` are kept as public extension points (Monad provides GRDB
  adapters, Yakamoz provides SwiftData adapters) — not a hypothetical single-conformer seam.
  Added 36 new contract test cases.

### Fixed

- Fixed unresolvable DocC symbol links in `Tool.identity`'s doc comment (broken since PKV3-012),
  which was failing `validate-docs`/`make verify`.

### Removed

- **Raw-text tool-call inference (`ToolOutputParser`)**: the fallback path in
  `ToolCallExtractionStage` that parsed XML `<<tool_call>` markers, pipe-delimited Qwen-style
  markers, and fenced JSON from assistant text into executable tool calls has been
  removed. Models must emit provider-native structured tool-call deltas; raw text
  containing legacy markers is now treated as ordinary content and does not produce
  `ChatEvent.toolCall` or tool accumulators. `ToolOutputParser` and its dedicated tests
  are deleted.

## [2.0.1] - 2026-07-11

### Changed

- **Public tool-passing call sites accept `[any Tool]` instead of `[AnyTool]`**:
  `ChatRunRequest.init(tools:)`, `AgenticRuntime.run(tools:)`, and
  `PositronicKit(foundationModelsTools:)` now take a plain `[any Tool]`, so callers no longer
  need to call `.toAnyTool()` on their own `Tool` conformances before passing them in. Existing
  callers passing `[AnyTool]` are unaffected — `AnyTool` still conforms to `Tool`. `AnyTool` now
  also overrides `toAnyTool()` to return `self`, so re-erasing an already-erased tool no longer
  silently resets its `provenance` to `.global`.

## [2.0.0] - 2026-07-10

> Note: a `[1.2.0] - 2026-07-07` changelog section briefly existed on `main`, but no `1.2.0`
> tag was ever cut (locally or on origin), so its entries ship here as part of `2.0.0`.

### Breaking

- **Converted the `PositronicKit` facade from `struct` to `final class`** (PKFAC-001): the facade
  is now a long-lived, `Sendable` reference-type configuration owner that owns exactly one
  internally constructed `TimelinePromptHistoryRegistry`. The `promptHistoryRegistry:` init
  parameter is removed — callers can no longer (and no longer need to) thread a shared registry
  through facade rebuilds; `addingPlugin(_:)`/`reconfigured(...)` return new instances that share
  the owner's registry internally. Hosts that reconstructed the facade per send to work around
  registry threading (the PKINT-007 caveat) can simply hold one instance.

- **Renamed `Tool.id` → `Tool.callName`** (PKAPI-002): the property is the callable name the
  LLM uses to invoke the tool (it becomes `LLMToolDefinition.name` on the wire), not an
  internal identifier. The old `id` name was misleading — it read as "internal identifier"
  rather than "the LLM-facing function name." `Tool.name` (human-readable display name) is
  unchanged. All PositronicKit conformers, call sites, and tests are migrated. Downstream
  consumers (Monad/Shuttle/Yakamoz) with custom `Tool` conformers need to rename `var id` →
  `var callName` on their next PositronicKit pin bump.
- **Removed `WorkspaceReference.metadata`** (PKAPI-014): the `[String: AnyCodable]` field was
  a dead passthrough — no production caller passed a non-empty dict, and no code read a key
  back or branched on it (only test round-trip assertions). The stored property, both inits,
  `withTools`, `primaryForTimeline`, and both `AgentWorkspaceServiceProtocol` requirements
  (`createWorkspace`/`createAgentWorkspace`) no longer accept a `metadata` parameter.
  Downstream consumers that pass `metadata:` to these methods need to drop the argument on
  their next PositronicKit pin bump. The Monad GRDB migration to drop the persisted column
  is deferred to the downstream phase (PKFAC-008).
- **Collapsed `PositronicKit` construction into `PositronicKit.Configuration`** (PKFAC-002): the
  flat 16-parameter initializer is removed. The public entry points are now the provider-agnostic
  `PositronicKit(llmService:)` convenience and the grouped `PositronicKit(configuration:)`.
  `PersistenceConfiguration.init` now takes every store as an optional and defaults missing
  stores to in-memory, matching the ergonomics of the old flat init. Internal reconfiguration
  paths continue unchanged. Downstream consumers using the flat initializer (none were found in
  Monad/Shuttle/Yakamoz) should migrate to `configuration:`; provider convenience inits are
  unaffected.
- Collapsed `HealthCheckable` to a single health probe (PKCLEAN-014): removed the unused
  `getHealthStatus()` requirement, keeping `checkHealth()` (live probe) and `getHealthDetails()`.
  `getHealthStatus()` had no callers through the protocol — Monad's `StatusAPIController` uses only
  `checkHealth()`/`getHealthDetails()` — and its in-package implementations duplicated `checkHealth()`.
  Conformers with a leftover `getHealthStatus()` method still compile (extra methods are allowed); no
  downstream migration is required.

- Renamed the compose-time observability seam to name its payload, not just its phase
  (PKAPI-015): `protocol TurnInspecting` → `PromptInspecting`,
  `func didComposeTurn(_:)` → `didComposePrompt(_:)`, `struct TurnInspection` → `PromptInspection`,
  and the `turnInspector` init parameter/property (all sites) → `promptInspector`. The payload is
  the fully composed, about-to-be-sent prompt (rendered prompt + sent messages + journal snapshot,
  no response yet), so the name now says *what you receive*. Shared correlation types in the same
  file (`TurnIdentity`, `TurnJournalSnapshot`) are unchanged. Downstream: Yakamoz's
  `SwiftDataTurnInspector` conformer is renamed to `SwiftDataPromptInspector` and its facade wiring
  updated on the next PositronicKit pin bump.

- Unified reasoning/thinking terminology across public types (PKAPI-003):
  `Message.think` → `Message.reasoning`, `LLMStreamDelta.thinking` → `LLMStreamDelta.reasoning`,
  `ChatEvent.DeltaEvent.thinking`/`.thinking(_:)` → `.reasoning`/`.reasoning(_:)`. `LLMMessage.reasoning`
  already used the right name. Provider-adapter wire-format field names are unchanged (Ollama's
  `thinking` JSON key, OpenRouter/OpenAI's `reasoning` JSON key, Anthropic's `thinking_delta` event
  type/field) — only PositronicKit's own shared vocabulary is affected. Downstream consumers
  (Monad/Shuttle/Yakamoz) pattern-matching `.thinking`/`Message.think` need migration on their next
  PositronicKit pin bump; Yakamoz's inspector drawer likely renders this field.

- `PositronicKit` facade fluent naming (PKAPI-005): **renamed `addPlugin(_:)` →
  `addingPlugin(_:)`**. the method is nonmutating
  (it returns a new facade instance with the plugin added — since PKFAC-001 the facade is a
  `final class`, and the new instance shares the owner's prompt-history registry), so it now
  follows the participle-form
  convention already used by `reconfigured(...)` on the same type, instead of the bare
  imperative verb that reads like an in-place mutation. The package-internal `addStage(_:)`
  was renamed to `addingStage(_:)` for the same reason (no downstream impact — it isn't
  public). Grepped Monad/Shuttle/Yakamoz for `.addPlugin(`/`.addStage(`: no call sites found,
  so no downstream migration is required for this change.
- **Renamed `MemorySavePolicy.preventSimilar(threshold:)` → `.deduplicating(threshold:)`**
  (PKAPI-010): the case previously read as an imperative verb phrase, inconsistent with
  its sibling cases `.immediate`/`.deferred`, which are adjectives describing *when* a
  save happens. `.deduplicating(threshold:)` matches that grammar. Downstream consumers
  (Monad/Shuttle/Yakamoz) reference the `MemorySavePolicy` type name in a few places but
  none currently pattern-match `.preventSimilar`, so no call-site migration is required
  there; verify on the next PositronicKit pin bump regardless.
- Session/timeline terminology cleanup (PKAPI-012): `TimelinePersistenceProtocol.saveTimeline`'s
  parameter label changed from `_ session: Timeline` to `_ timeline: Timeline`. This is a
  **protocol requirement**, so it is source-breaking for any external conformer that spells out
  the parameter name explicitly (Swift matches protocol requirements structurally, not by
  parameter name, so most conformers are unaffected — but Monad's `TimelineRepository` conformer
  (`Monad/Sources/MonadServer/Services/Database/Repositories/TimelineRepository.swift:16`) still
  uses `_ session: Timeline` and should be renamed to match on its next PositronicKit pin bump for
  consistency, even though it isn't required to compile). Also renamed `TimelineToolManager`'s
  logger label (`"session-tool-manager"` → `"timeline-tool-manager"`) and
  `RuntimeToolPolicyFactory.createToolManager`'s internal `session` parameter/binding to
  `timeline` (external label `for:` unchanged, non-breaking).
- `ChatEvent` enum ergonomics overhaul (PKAPI-004):
  - **Renamed `ToolExecutionStatus.failure(String)` → `.executionError(String)`** to
    eliminate the name collision with `.failed(reference:error:)`. The two cases had
    near-synonym names for structurally different payloads; `.executionError` now reads
    distinctly at the call site. `ToolResult.failure(_:)` (the static factory that
    constructs a failed `ToolResult` value) is **kept as-is** — it mirrors
    `Result.failure` semantics (a result constructor, not a lifecycle status) and does
    not collide with `ToolExecutionStatus` cases. The distinction: `ToolResult.failure`
    constructs a failed *result value*; `ToolExecutionStatus.executionError` is a
    *lifecycle status* for an error without a tool reference.
  - **Flattened `ChatEvent`'s wrapper cases:** `case delta(event: DeltaEvent)` →
    `case delta(DeltaEvent)`, same for `.meta`/`.error`/`.completion` (unlabeled, matching
    `Result.success`/`.failure` convention). The redundant `event:` label repeated the
    case name and forced double pattern-matching. All switch/pattern-match call sites in
    PositronicKit Sources and Tests were updated. The existing flattening factories
    (`.thinking(_:)`, `.generation(_:)`) and computed properties (`textContent`,
    `thinkingContent`) are unchanged. Downstream consumers (Monad/Shuttle/Yakamoz) have
    labeled-pattern call sites that will need migration when they bump to the release
    including this change; see the downstream grep in the ticket.
  - **Moved blocked-error classification onto `PKError`:** added `var isBlocked: Bool`
    (default `false`) to the `PKError` protocol, overridden `true` on
    `ToolError.permissionDenied`, `ToolError.attachedToolsDisallowedOnPrivateTimeline`,
    `PathSanitizer.PathError.accessDenied`, and `WorkspaceError.accessDenied`.
    `ChatEvent.ErrorIdentity` now carries a stored `isBlocked` field populated by
    `extracting(from:)` from `PKError.isBlocked` at extraction time, replacing the
    hand-curated `static let blocked: Set<ErrorIdentity>` of hardcoded `(domain, code)`
    pairs. `ErrorIdentity.init(domain:code:)` defaults `isBlocked` to `false` (directly
    constructed identities are not derived from a concrete error). `ErrorIdentity`'s
    `Equatable`/`Hashable` consider only `domain`+`code` (identity); `Codable` decodes
    `isBlocked` with a `false` default for backward compatibility. The removed
    `static let blocked` set was a public API; downstream consumers referencing it must
    switch to `identity.isBlocked` or `ErrorIdentity.extracting(from:)`.
- Provider/LLM parameter ergonomics (PKAPI-007):
  - **`ExternalLLMProviderRegistry.Factory`** is now `@Sendable (ProviderFactoryRequest) ->
    (any LLMClientProtocol)?` instead of an unlabeled 5-tuple closure
    `(LLMConfiguration, EndpointComponents, TimeInterval, Int, String?) -> ...`. The new
    `ProviderFactoryRequest` struct (`config`/`components`/`timeout`/`retries`/`model`) makes
    every field self-documenting at the call site; all 5 provider targets
    (`PKOpenAIProvider`, `PKOpenRouterProvider`, `PKOllamaProvider`, `PKAnthropicProvider`,
    `PKFoundationModelsProvider`) updated their `register()` factory closures accordingly.
  - **`LLMStreamClient.chatStream(...)`'s `useUtilityModel`/`useFastModel` boolean pair is
    replaced by a single `modelTier: ModelTier` parameter** (`.primary`/`.utility`/`.fast`).
    The previous two-boolean signature was ambiguous when both were `true` (undocumented
    precedence: `useFastModel` checked first, then `useUtilityModel`, then primary);
    `ModelTier` makes tier selection exhaustive and self-documenting. `LLMChatRequest.useFastModel:
    Bool` renamed to `modelTier: ModelTier`. `LLMUtilityClient.sendMessage(...useUtilityModel:)`
    is unrelated and unchanged (only the streaming boolean pair is affected).
  - Documented (not restructured) `LLMConfiguration`'s backwards-compatibility computed
    properties (`endpoint`/`apiKey`/`modelName`/etc.) as write-through proxies onto
    `providers[activeProvider]` — reading/writing them mutates the active provider's
    `ProviderConfiguration` in place; there is no independent top-level state underneath.

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
- **Converted `formatToolsForPrompt(_:)` free function to `[AnyTool].formattedForPrompt()`**
  (PKAPI-009): the free function's sole parameter was the receiver (`[AnyTool]`), so it is now
  `extension [AnyTool] { func formattedForPrompt() async -> String }`. Stayed `async` because it
  awaits `tool.canExecute()` per element. Updated all in-repo call sites (`PromptSections.swift`,
  `PositronicKitExamples/main.swift`, `ExampleUsageStoriesTests.swift`). A grep of
  Monad/Shuttle/Yakamoz found no call sites, so downstream impact is nil.

### Added

- Added the tier-4 `AgenticRuntime` facade (PKFAC-006): `kit.agenticRuntime(timelineId:agentInstanceId:)`
  vends a named entry point over the agent tool-loop, and the facade now eagerly owns a public
  `agentInstanceManager` constructed with its own `TimelineManager` (so hosts no longer rebuild
  and rebind their own `AgentInstanceManager` post-construction).
- Documented `AnyPrompt` as a concatenating prompt group, not a type erasure (PKAPI-006).
  The `Any` prefix signals "accepts any `Prompt`," not "erases a single concrete type" —
  the doc comment now makes this distinction explicit. Non-breaking, docs-only.
- Documented the five-tier facade ladder, from timeline-free one-shot operations through
  `Conversation`, `TimelineManager`, `AgenticRuntime`, and raw primitives, with compile-checked
  examples for the recommended application-owned Service pattern.
- Added timeline-free `PositronicKit.complete(_:)` and `stream(_:)` one-shot APIs. They send a
  minimal user prompt directly through `LLMStreamClient` and do not persist runtime state.
- Added the opt-in `PKObservable` product with an `@Observable` `ObservableConversation` wrapper
  that mirrors `Conversation` streaming state for SwiftUI-facing consumers.
- Added the `Conversation` cursor API: `newConversation(title:)` persists one timeline and
  workspace, `conversation(timelineId:)` returns a fresh pure cursor, and `send(_:)` delegates
  through the existing facade chat path. Cursors expose stable `Identifiable` timeline identity
  and scoped `TimelineManager` access.

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
- `PositronicKit.RuntimeConfiguration.toolApprovalGate` (PKAPI-008): the grouped initializers
  in `PositronicKit+Configuration.swift` (both the `runtime: RuntimeConfiguration` overload and
  the persistence-grouped `init(llmService:persistence:...)`) now expose `toolApprovalGate` and
  thread it through to the facade-built `ToolRouter`. Previously a host using the "recommended"
  grouped API silently got `DenyAllToolApprovalGate` with no way to inject a real approver
  without dropping to the flat initializer. Additive and non-breaking — the default remains
  `DenyAllToolApprovalGate()`, preserving existing behavior.

- Tests: `SidecarOutcomeContractTests` pinning the `SidecarStreamExtractor` outcome shape for
  leaf-scalar and object-schema directives, `null` → `.declined`, missing/wrong key → `.failed`,
  `Codable` round-trip preserving the `AnyCodable` case tag, and a strict-mode contract test
  asserting that composed sidecar schemas list every payload property in `required` and emit
  `additionalProperties: false` under `strict: true` (PKTEST-1 investigation; the conflict it
  surfaced is fixed by PKTEST-3).

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

- API-audit documentation pass over the new facade-tier surfaces: added missing doc comments on
  `Conversation`, `AgenticRuntime`, `ObservableConversation`, and the grouped
  `PersistenceConfiguration`/`RuntimeConfiguration` members; de-duplicated the repeated
  operation-ladder paragraph in the `PositronicKit` facade doc comment; simplified a redundant
  rethrow in `ObservableConversation.consume`. No behavior change.
- `TimelineManager` query/mutation split (PKAPI-005): the ticket described
  `getTimeline(id:)` as package-internal, but it is in fact `public` and already consumed
  directly by downstream hosts (e.g. Monad's `ChatAPIController`/`TimelineAPIController`),
  so its `get`-prefixed-but-mutates-`updatedAt` signature was kept as-is for backward
  compatibility rather than renamed/removed. Instead, added a pure `timeline(id:) ->
  Timeline?` query and an explicit `touchTimeline(id:)` mutation; `getTimeline(id:)` is
  now implemented in terms of both (touch, then pure lookup). The one internal call site
  that didn't need the touch side effect (`ToolRouter.determineExecutionOutcome`'s
  private-timeline check) was switched to the pure `timeline(id:)` query; the per-turn
  read in `ChatEngine+TurnPreparation.swift` keeps using `getTimeline(id:)` since a turn
  starting is a legitimate activity signal.
- Documented the `dryRun: Bool` contract on `MessageStoreProtocol.pruneMessages(olderThan:dryRun:)`,
  `TimelinePersistenceProtocol.pruneTimelines(olderThan:excluding:dryRun:)`, and
  `MemoryStoreProtocol.pruneMemories(matching:dryRun:)` /
  `pruneMemories(olderThan:dryRun:)` (PKAPI-013): `dryRun: true` computes and returns the row
  count that *would* be deleted without deleting anything; conformers must not mutate persisted
  state in dry-run mode. Verified the in-package `InMemory*` stores and `PKTestSupport`'s `Mock*`
  stores honor this (their `prune*` methods are unconditional no-ops regardless of `dryRun`) and
  added `Tests/PositronicKitTests/Services/PruneDryRunTests.swift` pinning the behavior down so a
  future real implementation can't silently violate it. Docs-only for the protocol signatures — no
  API shape changed.
- Tightened the doc comment on `PromptJournal.reset(hard:)` (PKAPI-013) to spell out what
  `hard: true` vs. the default `false` each clear (in-flight observation only vs. also the
  committed base). Kept as documentation-only, per the ticket's guidance not to force a breaking
  change for a documented default-false flag absent real call-site confusion: grepped the
  codebase and found zero call sites of `reset(hard:)` outside its own definition, so there is no
  confusion to resolve via an enum/split-method reshape.
- `Tool.canExecute()` doc comment corrected (PKAPI-001): it was documented as "whether the tool
  is currently available for execution in the given environment" but takes no environment
  parameter — no conformer depends on an injected context. The comment now reads "whether the
  tool is currently available for execution."

- Build-surface housekeeping (PKCLEAN-009): documented in `Package.swift` why
  `PositronicKitTests` still depends on `PositronicKitExamples` — the
  `Tests/PositronicKitTests/Stories/Examples/*.swift` files exercise
  `PKPromptExamples`/`PositronicKitUsageExamples` behaviorally (not a trivial compile
  check), so dropping the dependency would lose coverage rather than relocate it.
  Confirmed `PKFastEmbed` is already target-only (no library product) and unused by
  Monad/Shuttle/Yakamoz directly; no further change needed there.

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

### Deprecated

- `PositronicKit.CompactionThresholds` is now a deprecated typealias for
  `PKPrompt.PromptJournalCompactionThresholds` (the surviving public name). The runtime's
  `TimelinePromptHistory` and `TimelinePromptHistoryRegistry` now consume
  `PromptJournalCompactionThresholds` directly. Source callers passing
  `CompactionThresholds(...)` continue to compile with a deprecation warning; migrate to
  `PromptJournalCompactionThresholds`. No downstream consumers (Monad, Shuttle, Yakamoz)
  reference either name today.

### Removed

- **Breaking (unreleased API):** removed `AgenticRuntime.workspaceId` and the `workspaceId:`
  parameter of `PositronicKit.agenticRuntime(timelineId:agentInstanceId:)`. The value was a dead
  passthrough — stored on the handle but never read and never forwarded into the turn
  (`ChatRunRequest` has no workspace parameter); workspace routing is resolved from timeline
  attachments and tool provenance. Both symbols were introduced after 1.1.0 (PKFAC-006), so no
  released consumer is affected.
- **Breaking:** removed three dead public types found in the pre-release audit, each with zero
  references across PositronicKit sources/tests and all three consumers (Monad, Shuttle, Yakamoz):
  `PKShared.ToolConfiguration` (per-session tool enable/disable record that nothing persisted or
  read), `PositronicKit.WorkspaceToolError` (single-case error enum never thrown), and
  `PositronicKit.InMemoryKeyValueStore` (in-memory `KeyValueStoreProtocol` conformance nothing
  constructed — the protocol itself is kept; Monad's `DatabaseKeyValueStore` conforms to it).
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
