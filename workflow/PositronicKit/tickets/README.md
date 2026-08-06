# PositronicKit — Tickets

**Overall status:** 196 closed (archived), 0 open in this local tracker.
Closed tickets live in [`archive/`](archive/).

> **Tracker note (2026-08-06):** PositronicKit is now tracked in the standalone
> `phynics/PositronicKit` repo. Open work is filed as GitHub issues there; this
> directory keeps the archived/closed batch history. The last open local ticket,
> `PKAPI-004`, was migrated to
> [phynics/PositronicKit#14](https://github.com/phynics/PositronicKit/issues/14).

## Open backlog

_None — open work lives as GitHub issues on `phynics/PositronicKit`._

### Closed: PKAPI-001…003 — COMPLETE

Completed 2026-08-04 for PositronicKit 3.4.0 (`7aeb3ca`). The Swift API Design Guidelines review
added source-compatible canonical core, PKPrompt, provider, embedding, and test-support APIs;
preserved wire formats and deprecated forwarding shims; and migrated ordinary call sites. Final
gates passed with 1,637 tests in 242 suites plus all-products, MiniLM, and current-Linux checks.

### Closed: PKCR-001…010 — COMPLETE

Filed from a code-review pass on pinned revision `a354632` (3.2.0 release).
Covered: dead code, duplicated types, duplicated provider logic, unused imports,
large-file splitting, and medium code smells. 4 P0, 6 P1/P2.

**Resolution:** Completed 2026-07-29. See the archived ticket files for per-ticket details.
All implementation changes passed `make verify` with 1610 tests in 238 suites.

### PositronicKit remediation review (PKRR-001…030) — 2026-07-28

Filed from a static architecture/API/reliability/error-handling/logging/ergonomics
review of pinned revision `90646771bd113ae5ffa63816a18153f5fcf9dc9c` (current HEAD of
`PositronicKit` at filing time). 30 actionable findings: **5 P0, 15 P1, 9 P2, 1 P3**.
Series prefix is `PKRR` (PositronicKit Remediation Review) — the legacy `PKR-1…15`
prefix belongs to the archived 2026-07-02 four-track repo review and is not reused.

**Tranche A progress (5 P0s):** all 5 P0s are **Done** (implemented 2026-07-28, merged to
PositronicKit `main` at `8b9d1d1`, 1394 tests in 211 suites pass). Tranche A is complete.

**Tranche B progress:** PKRR-006, 007, 008, 009, 015, 016, 017 are **Done** — Tranche B is
**COMPLETE** (merged to `main` at `7cee460`, 1465 tests in 219 suites pass). See the closed
summary below for per-ticket resolution details.

**Tranche C progress:** PKRR-010, 011, 014, 018, 019, 020, 021 are **Done** — Tranche C is
**COMPLETE** (merged to `main` at `df390bd`, 1518 tests in 224 suites pass).

**Tranche D progress:** PKRR-012, 013, 022, 024, 025, 026, 027, 028, 029, 030 are **Done**.
SDC-10 is also **Done** (merged to `main` at `8202e05`, 1598 tests in 237 suites pass).

**Review scope/limitations (recorded on every ticket):** the review was static-only.
The planning runtime had Swift 6.2.1/Git/LibreOffice but no Docker/Xcode/Rust, and
could not clone GitHub — so the package build and its ~1,341-test suite were **not**
independently executed. Findings marked "Confirmed" are supported by direct
control-flow/API evidence, not runtime verification. PKRR-028 (orphaned APIs) is
intentionally a candidate set and requires `swift symbolgraph-extract` + downstream
scans before any removal. Per the filing decision, all 30 were filed verbatim from
the review without pre-verification; agents should still add a regression test that
reproduces the current behavior before fixing (each ticket's first acceptance
checkbox).

**Triage scheme:** P0/P1 → `ready-for-agent`, except PKRR-004/005/017 which were
initially `needs-info` pending design decisions — **all three decisions were made
on 2026-07-28** (see
[`specs/2026-07-28-pkrr-004-005-017-design-decisions.md`](../specs/2026-07-28-pkrr-004-005-017-design-decisions.md))
and the tickets are now `ready-for-agent`; P2/P3 → `needs-triage`. PKRR-028 also
requires symbol-graph verification (noted in its body) even though its label is
`needs-triage`.

**Implementation sequence (4 tranches, from the review):**

- **Tranche A — lock terminal/execution invariants** (do first; add regression tests
  before refactoring): PKRR-001…005. Invariants: one active send per send handle,
  one terminal stream state, no post-terminal work, no uncertain write-side effects
  presented as stopped, no message without a valid timeline lifecycle outcome.
- **Tranche B — make persistence recoverable and idempotent**: PKRR-006…009, 015,
  016, 017, 023. Introduces `sendId` idempotency, lifecycle transactions/sagas,
  typed store errors, durable event ordering, cancellation-aware eviction.
  (PKRR-015 was not assigned to a tranche by the review; placed here thematically —
  tool-runtime fail-closed safety pairs with PKRR-016's durable event ordering.)
- **Tranche C — normalize cross-platform generation and public contracts**: PKRR-010,
  011, 014, 018, 019, 020, 021. Unifies the one-shot and timeline runners, true
  Linux streaming, terminal-event semantics, error causality, readiness state, and
  non-crashing prompt validation.
- **Tranche D — observability, API hygiene, and build confidence**: PKRR-012, 013,
  022, 024…030. Privacy/logging policy, structured degradation diagnostics,
  symbol-graph/API audits, compiled docs, Apple CI, bootstrap preflight.

**Key cross-ticket dependencies:** PKRR-023/019 depend on PKRR-002's task registry;
PKRR-006/016 depend on PKRR-005's lifecycle contract; PKRR-005/022 depend on
PKRR-008's not-found-vs-unavailable taxonomy; PKRR-019 depends on PKRR-011's
terminal-event contract; PKRR-021 depends on PKRR-001's budget separation and
PKRR-020's no-precondition rule; PKRR-027 depends on PKRR-011; PKRR-004 accepts
PKRR-030's validated timeout values.

### Closed: PKRR Tranche B (006, 007, 008, 009, 015, 016, 017) — COMPLETE

- **PKRR-006** — Done 2026-07-28, PositronicKit `958acd7`. Reordered `prepareSession` to
  defer `saveConversationSteps` until after history validation, context gathering, workspace
  lookup, and prompt assembly succeed. Added `TurnIdempotencyGate` actor rejecting duplicate
  `sendId`s with `ChatEngineError.duplicateSendId` (error code 9006). Refactored
  `ExternalToolOutputSubmissionGate` into validate/commit phases for resumable batches.
  5 idempotency-invariant tests with fault injection.
- **PKRR-007** — Done 2026-07-28, PositronicKit `b513d2c`. Reordered `createTimeline` to
  persist timeline record first, then create directory/notes/workspace, with compensating
  rollback on failure at each step. Reordered `attachWorkspace` to validate workspace
  existence before persisting attachment. 9 fault-injection tests.
- **PKRR-008** — Done 2026-07-28, PositronicKit `624ed02`. Expanded `TimelineError` with
  `corrupt`/`permissionDenied`/`invalidState` cases. Replaced `try?` in
  `TimelineManager+Lifecycle`, `+Attachments`, and `getToolSource` with typed error
  propagation. `getWorkspaces` now throws `WorkspaceQueryResult` with `StoreDegradation`
  diagnostics for partial failures. 21 store-error-classification tests.
- **PKRR-009** — Done 2026-07-28, PositronicKit `64ed6a0` (merge `e226d47`).
  `runPrimaryStages` returns `CancellationError()` when cancelled instead of returning
  `nil` (success). Cleanup failures collected as `PipelineError.compoundFailure` (error
  code 4003) so both primary and cleanup failures are observable. Cleanup always runs.
  4 cancellation-invariant tests + 1 updated existing test.
- **PKRR-015** — Done 2026-07-28, PositronicKit `8d5bd21`. When `workspaceID` is present
  in tool arguments, require a valid UUID matching a candidate workspace. Malformed values
  throw `ToolError.invalidWorkspaceID` (error code 213); valid-but-unmatched UUIDs throw
  `workspaceNotFound`. No more silent fallback to auto-routing. 3 fail-closed tests.
- **PKRR-016** — Done 2026-07-28, PositronicKit `335e740`. Reordered `ToolRouter` to call
  `messageStore.saveMessage` before `continuation.yield`. Persistence failures emit
  `.persistenceFailed` terminal status instead of `.success`/`.failed`. Added
  `ToolExecutionStatus.persistenceFailed` case to `ChatEvent`. 4 tool-durability-ordering
  tests.
- **PKRR-017** — Done 2026-07-28, PositronicKit `3f56885` (merge `9bad823`). Added
  `DurabilityAware` protocol (`isDurable`, default `false`) as parent for all 7 store
  protocols. `DurabilityReport` with `validateDurability()` on `PersistenceConfiguration`.
  `PositronicKit.init` logs `.warning` on mixed durability naming specific ephemeral stores.
  `.fullyPersistent(stores:)` static factory. Additive/backward-compatible. 19 durability
  tests.

### Closed: PKRR Tranche C (010, 011, 014, 018, 019, 020, 021) — COMPLETE

- **PKRR-010** — Done 2026-07-28, PositronicKit `84b1cc6` (merge `7cee460`). Replaced Linux
  `session.data(for:)` (buffers full response) with a `URLSessionDataDelegate`-based streaming
  implementation that yields complete lines as data chunks arrive. Apple path unchanged. No
  new dependencies. 7 streaming conformance tests. Linux compilation needs
  `make verify-linux-current` verification.
- **PKRR-011** — Done 2026-07-28, PositronicKit `9504242`. Added `.maxTurnsReached` and
  `.deferredForExternalTool` terminal states to `CompletionEvent`. Max-turn exhaustion now
  emits a distinct terminal event instead of silently finishing. Deprecated orphan cases
  retained for Codable compatibility. Updated `docs/Usage.md`. 6 terminal-event-uniqueness
  tests. Additive/deprecation — backward-compatible.
- **PKRR-014** — Done 2026-07-28, PositronicKit `d420581`. Added `CausalError` protocol for
  cross-module causal chain traversal. `ErrorIdentity.extracting` now recurses through wrappers
  (`PipelineError`, `LLMStreamError`) to find the root `PKError` identity. Provider 429s,
  blocked tool errors, and cancellation retain their identity through pipeline wrapping.
  23 error-causality tests (19 unit + 4 integration).
- **PKRR-018** — Done 2026-07-28, PositronicKit `a03d540`. Added `isReady` property requiring
  valid configuration AND a resolved primary client. `isConfigured` retains configuration-only
  semantics (backward-compatible). Health details distinguish invalid config vs missing client
  factory vs ready. Added `LLMServiceError.clientNotResolved` (error code 1008). 6 regression
  tests.

- **PKRR-019** — Done 2026-07-28, PositronicKit `bbd6fc7` (merge `ecd0b63`). Added
  `OneShotResult` with content, usage, finish reason, ID, and model; per-call generation
  parameters; shared idle-timeout/cancellation runner with timeline streaming. Stalled-stream
  and cancellation regression tests added.
- **PKRR-020** — Done 2026-07-28, PositronicKit `f08730c` (merge `ecd0b63`). Replaced
  recoverable preconditions with typed errors; missing prompt diffs now fail only the affected
  turn with diagnostic state. Added duplicate-ID, invalid-budget, and journal-transition tests.
- **PKRR-021** — Done 2026-07-28, PositronicKit `d61ae41`. Added verified `TokenBudgetResult` API
  with hard budget enforcement. Mandatory `.keep` sections fail typed when impossible. Summarizer
  errors preserved instead of swallowed. Migrated `PromptAssembler`.

### Closed: PKRR Tranche D (012, 013, 022, 024, 026, 027, 030)

- **PKRR-012** — Done 2026-07-28, PositronicKit `dafb401` (merge `26dc2c5`). Added
  `DiagnosticSnapshotConfiguration` with off/metadataOnly/redacted/full policies, byte limits,
  truncation, and secret redaction. Default events no longer build rich snapshots; full snapshots
  require explicit opt-in. Preserved `turnSnapshotData` compatibility. Privacy/policy tests added.
- **PKRR-013** — Done 2026-07-28, PositronicKit `674d229` (merge `faa4bcc`). Added
  `LoggingConfiguration` with default-off `LogRedactionPolicy` injectable through
  `PositronicKit.Configuration`. Request descriptions, malformed tool arguments, tool errors,
  ANSI escapes, and emoji no longer enter default structured logs. Error logs carry stable
  domain, code, and correlation metadata.
- **PKRR-022** — Done 2026-07-28, PositronicKit `f52ac9f` (merge `df390bd`). Added
  `TurnDegradationPolicy` and `TurnDiagnostic`. Default `failRequired`; required failures abort
  before generation. Optional failures emit structured diagnostics in `generationContext`
  metadata. Origin lookup remains optional and observable.
- **PKRR-024** — Done 2026-07-28, PositronicKit `a3d40d8`. Added `colorize(_:color:enabled:)`
  gate and `strip(_:)` to `ANSIColors`. `LogRedactionPolicy.sanitize` delegates to
  `ANSIColors.strip`. Legacy `colorize(_:color:)` kept public for downstream consumers.
  10 regression tests.
- **PKRR-027** — Done 2026-07-28, PositronicKit `b1a5d20`. Fixed all stale snippets in
  `docs/Usage.md`: grouped `Configuration` init, `ChatRunRequest`, current event case names.
  Added `compile-doc-snippets` Makefile target wired into `verify`.
- **PKRR-030** — Done 2026-07-28, PositronicKit `9e20e79` (merge `8bf1975`). Added
  `RetryConfiguration` (maxRetries ≤ 10, finite delays, maxRetryAfter cap, total-elapsed budget,
  injectable jitter) and `Timeout` (overflow-safe). `RetryPolicy` validates via
  `RetryConfiguration`. `ProviderHTTPFailure` rejects non-finite `Retry-After`.
  `ToolTimeoutEnforcer` uses `Timeout`. 48 new tests. Additive/backward-compatible.
- **PKRR-023** — Done 2026-07-28, PositronicKit `bc91aec`. Renamed `deleteTimeline` to
  `evictTimelineFromMemory` (cancels/drains active work via `TimelineTaskRegistry` before
  eviction). Added `deleteTimelinePermanently` returning `TimelineDeletionResult` with
  partial-cleanup reporting. Deprecated alias retained. 7 eviction/deletion tests.
- **PKRR-026** — Done 2026-07-28, PositronicKit `a44a06a` (merge `c3d61fa`). Moved
  `swift package describe` from parse-time to `verify-products` recipe. Added `doctor`
  target with actionable prerequisite checks. Container targets fail with one clear message
  when no runtime exists. `make help` works without Swift on PATH.

### Closed: PKRR Tranche A (001, 002, 003, 004, 005) — COMPLETE

- **PKRR-001** — Done 2026-07-28, PositronicKit `97b65a8` (merge `8b9d1d1`). Added
  `contextWindowTokens` to `ProviderConfiguration` with per-provider defaults (OpenAI/
  OpenRouter 128k, Anthropic 200k, Ollama 8k). Added `TokenBudget.init(contextWindow:
  outputReserve:)` with typed `TokenBudgetError` validation. `ChatEngine.makeTokenBudget`
  derives budget as `contextWindow - (maxOutput ?? 4096) - 512 overhead`. A 512-token
  output limit no longer compresses a prompt that fits the context window. 18 new tests.
- **PKRR-002** — Done 2026-07-28, PositronicKit `d318dc7`. Added `TimelineTaskRegistry`
  actor mapping `(timelineID, sendID) -> Task`. `ChatEngine.execute` registers its
  stream-driving task and removes it on every terminal path. `TimelineDriver.cancel()`
  cancels the active send's task. Eviction/deletion cancels and awaits bounded cleanup.
  Send-scoped handles ensure a stale cancellation cannot terminate a newer send. 8 new
  cancellation-invariant tests.
- **PKRR-003** — Done 2026-07-28, PositronicKit `ad73609`. Replaced binary `.stop`/
  `.continueWith` loop signal with typed `.completed`/`.continueWith`/`.failed`/
  `.cancelled`; only `.completed` runs `ChatTurnFollowUpPolicy`. 5 terminal-invariant
  tests prove no plugin/message/LLM activity after provider failure, cancellation, or
  pipeline-stage failure.
- **PKRR-004** — Done 2026-07-28, PositronicKit `16c1ed3` (merge `82fd645`). Added
  public `ToolSideEffects` enum (`.none`/`.mutating`/`.externalProcess`) to PKShared
  with `.mutating` default; `AnyTool` forwards it. `ToolTimeoutEnforcer` throws
  `ToolError.timedOutButMayStillBeRunning` (error code 212) for `.mutating`/
  `.externalProcess`, clean `executionFailed` for `.none`. 11 new tests.
  Additive/backward-compatible.
- **PKRR-005** — Done 2026-07-28, PositronicKit `4bd8baa` (merge `5fb845b`).
  `openTimeline(_:)` is now fail-closed (open-existing-only); missing ID throws
  `TimelineError.timelineNotFound` before `saveConversationSteps`. Added
  `TimelineError.unavailable` (code 6002). `resolveTurnBriefingBuilder` is now
  `throws`. 4 existing test files updated; 6 new lifecycle-invariant tests. All 3
  consumers already create explicitly — no downstream migration.

| ID | Title | Priority | Triage |
|----|-------|----------|--------|
| PKRR-001 | Response `maxTokens` used as the prompt context-window budget | P0 | Done `97b65a8` |
| PKRR-002 | Timeline cancellation API disconnected from active chat tasks | P0 | Done `d318dc7` |
| PKRR-003 | Failed turn continues into plugin follow-up after terminal failure | P0 | Done `ad73609` |
| PKRR-004 | Timed-out tools abandoned, may keep mutating state after failure | P0 | Done `16c1ed3` |
| PKRR-005 | `openTimeline` promises create-on-first-send that is unimplemented | P0 | Done `4bd8baa` |
| PKRR-006 | Turn input persisted before preparation; tool-output batches non-atomic | P1 | Done `958acd7` |
| PKRR-007 | Timeline creation/workspace attachment can leave partial state | P1 | Done `b513d2c` |
| PKRR-008 | Persistence/resolution errors collapsed into not-found or empty | P1 | Done `624ed02` |
| PKRR-009 | Pipeline cancellation can be reported as success; cleanup failures hidden | P1 | Done `64ed6a0` |
| PKRR-010 | Linux provider streams buffer the full HTTP response before yielding | P1 | Done `84b1cc6` |
| PKRR-011 | Terminal events emitted inconsistently; max-turn exhaustion looks successful | P1 | Done `9504242` |
| PKRR-012 | Unconditional rich diagnostic snapshot in response metadata | P1 | Done `dafb401` |
| PKRR-013 | Logging has no redaction policy; can expose payload fragments | P1 | Done `674d229` |
| PKRR-014 | Pipeline wrapping destroys underlying error identity | P1 | Done `d420581` |
| PKRR-015 | Malformed explicit `workspaceID` silently falls back to auto routing | P1 | Done `8d5bd21` |
| PKRR-016 | Tool success/failure emitted before the tool message is durable | P1 | Done `335e740` |
| PKRR-017 | Partially persistent configs silently mix durable and in-memory state | P1 | Done `3f56885` |
| PKRR-018 | `LLMService` can report configured with no client capable of sending | P1 | Done `a03d540` |
| PKRR-019 | One-shot streaming weaker than timeline chat (timeout/observability/params) | P1 | Done `bbd6fc7` |
| PKRR-020 | Public/runtime paths use preconditions for recoverable invalid state | P1 | Done `f08730c` |
| PKRR-021 | `TokenBudget` enforces no hard upper bound; hides summarizer errors | P2 | Done `d61ae41` |
| PKRR-022 | Context/agent/origin/workspace failures silently remove turn features | P2 | Done `f52ac9f` |
| PKRR-023 | `deleteTimeline` only evicts memory; does not cancel active work | P2 | Done `bc91aec` |
| PKRR-024 | ANSI color codes and glyphs embedded in swift-log records | P2 | Done `a3d40d8` |
| PKRR-025 | CI does not exercise the documented verification matrix | P2 | Done `8c778c8` |
| PKRR-026 | Makefile does package discovery at parse time; no container runtime guard | P2 | Done `a44a06a` |
| PKRR-027 | Usage docs contain non-compiling event names and stale construction APIs | P2 | Done `b1a5d20` |
| PKRR-028 | Orphaned/test-only public APIs need an intentional disposition | P2 | Done `4f69e6f` |
| PKRR-029 | Timeline creation writes temp workspace notes with no retention story | P2 | Done `671a29c` |
| PKRR-030 | Retry/timeout knobs accept invalid or unbounded values | P3 | Done `9e20e79` |

### Release-hygiene tranche (PKHYG-001…005) — COMPLETE

All 5 tickets closed. See closed summary below.

### Closed: PKHYG series

- **PKHYG-001** — Added `Scripts/list-library-products.swift`; Makefile `PRODUCTS` now derived
  from `swift package describe --type json`. Added `verify-examples`/`verify-tests` targets.
  `verify` composes products/examples/docs/linkage/tests. 948 tests green. PositronicKit `8c0f6f9`.
- **PKHYG-002** — Deleted `PKTestSupport` from public product surface. Target remains in
  `Tests/PKTestSupport`; all test dependencies preserved. PositronicKit `b3230b0`.
- **PKHYG-003** — Created 5 provider test targets; moved 12 provider suites and 8 PKShared tests
  out of `PositronicKitTests`. Core no longer depends on provider targets. PositronicKit `1607150`.
- **PKHYG-004** — Deleted duplicative `Sources/PositronicKit/README.md`; extended `validate-docs.sh`
  with authority contracts for `docs/index.html` and `llms.txt`. PositronicKit `b890e08`.
- **PKHYG-005** — Deleted `ToolOutputParser` and fallback text-parsing in `ToolCallExtractionStage`.
  XML/pipe/fenced-JSON assistant text no longer produces tool calls. CHANGELOG updated.
  PositronicKit `4a9a59d`.

### v3 vocabulary and composition (PKV3-001…015)

Filed 2026-07-12. Back references:
[design spec](../specs/2026-07-12-v3-vocabulary-and-composition-design.md) ·
[implementation plan](../plans/2026-07-12-v3-vocabulary-and-composition.md).
This breaking-major batch replaces overlapping public terminology with explicit roles: direct
LanguageModel injection, user-extensible workspace resolution, TimelineDriver, tool registration/
execution roles, turn briefing/prompt journals, compatibility removal, PKUtilities, and module
deepening. Split into three parallel tracks (Composition/providers: 001→009→011, +008;
Workspace/timeline: 002→003→010; Tools/prompts/cleanup: 004→012, +005/007/013), all now merged
to `main` (Track 1 `347e554`, Track 2+3 `9c5094e`..`b7af773`, PKV3-014 `07c1dbf`, PKV3-010 gap fix
`789a645`) — see the closed-batches notes below for per-track resolution detail. `make verify` is
fully green on `main` (963 tests / 167 suites) — a pre-existing DocC gate bug (unresolvable
symbol links in `Tool.identity`'s doc comment, broken since PKV3-012) was found and fixed along
the way.

**Prerelease cut for consumer verification**: tagged and pushed `3.0.0-beta.1` then
`3.0.0-beta.2` (the latter restores `PKTestSupport` as a public product — `PKHYG-002`, an
already-closed unrelated ticket, had removed it on a mistaken "no downstream migration
required" premise that only surfaced once a consumer finally resolved against a post-PKHYG-002
tag). Monad's build against `3.0.0-beta.2` surfaced real gaps beyond simple renames:

- **Fixed in PositronicKit**: `TimelineManager` had no public way to read/enable/disable a
  timeline's tools after PKV3-010 made `getToolManager(for:)` internal — added
  `enabledTools(for:)`/`enableTool(id:for:)`/`disableTool(id:for:)` (commit `789a645`, not yet
  in a tagged prerelease).
- **Found, not yet fixed — filed as PKV3-015**: PKV3-001 deleted the provider registry with no
  replacement for *dynamic* runtime provider-client swapping on config change (`LLMService`'s
  `updateClient(with:)` calls a dead `Self.makeClients(with:)` stub). Blocks Monad's
  `ConfigurationAPIController` flow and its `LLMProviderBootstrap.swift`. Needs a design
  decision (injectable client-factory hook vs. host-owned reconstruction) before Monad can
  fully build against a v3 tag.

Monad has a full source-level pre-migration commit (`15843d2`, this repo) for every other v3
rename/relocation, verified by a temporary local pin flip to `3.0.0-beta.2` + `swift build`
(then reverted). The PKV3-015 blocker was resolved 2026-07-15, and all three consumers have been
migrated, verified against a local v3 override, and pinned to `3.0.0`. The `3.0.0` tag was created
locally on PositronicKit `81eeb7a` and needs to be pushed to origin before the consumer pins
resolve.

- **PKV3-015** — Done 2026-07-15: injectable client-factory hook replaces dead
  `makeClients(with:)`; Monad's `LLMProviderBootstrap` migrated to per-provider
  `makeClient(configuration:)` factories. PositronicKit `7295316`.
- **PKV3-006** — Done 2026-07-15: all consumers migrated and pinned to `3.0.0`; source
  migration map added to `CHANGELOG.md`; `3.0.0` tag created locally. PositronicKit `81eeb7a`,
  Monad `e5bec00`, Shuttle `552a3c3`, Yakamoz `4f3a3ba`.

| ID | Title | Priority | Triage |
|----|-------|----------|--------|
| _(none — PKV3 series complete)_ | | | |

### Closed: PKV3 Track 3 (004, 005, 012, 013)

- **PKV3-004** — Renamed `ToolProviding`→`ToolSource`, `provideTools()`→`tools()`,
  `ToolProvenance`→`ToolOrigin`, `TimelineToolManager`→`TimelineToolRegistry`,
  `ToolApprovalGate`→`ToolApprovalPolicy`. All conformers, call sites, tests, examples migrated.
  PositronicKit `8c686fc`.
- **PKV3-012** — Added `Tool.identity` (default `.known(id: callName)`). `AnyTool` captures
  immutable `ToolReference` + `ToolOrigin` at erasure. Deleted `ToolReferenceProviding` and
  dynamic-cast fallback. `withOrigin(_:)` for origin-stamping copies. PositronicKit `c816316`.
- **PKV3-005** — `ContextManager`→`TurnBriefingBuilder`, `TimelinePromptHistoryRegistry`→
  `TimelinePromptJournals` (internal), `PromptInspecting`→`PromptObserving`. `TurnBriefing`
  typealias added. PositronicKit `701f0fe`.
- **PKV3-013** — Both `AgentInstanceStoreProtocol` and `RequestOriginStoreProtocol` KEPT
  (Monad provides GRDB adapters, Yakamoz provides SwiftData adapters). Contract tests added
  (36 new cases). PositronicKit `701f0fe`.

### Closed: PKV3 Track 2 (002, 003, 010) + Track 1 (001, 008, 009, 011) + partial 007

- **PKV3-002 / PKV3-003** — see the closed-batches note below (2026-07-13 entry) for full detail:
  `Workspace`/`WorkspaceResolver` vocabulary rename + injected resolver, and
  `Conversation`→`TimelineDriver`/`TimelineController`. Merged to `main` `9c5094e`.
- **PKV3-010** — `TimelineManager.workspaceResolver` and `getToolManager(for:)` no longer
  public; narrowed to lifecycle/attachment/query operations. PositronicKit `2b0a200`.
- **PKV3-007 (partial)** — deleted `CompactionThresholds`/`EmptySection` typealiases and
  `TimelineManager.getTimeline(id:)` (migrated to `timeline(id:)`/`touchTimeline(id:)`,
  including downstream Monad call sites); lowered `StreamingParser` to internal (no external
  consumer); kept `VectorMath`/`ANSIColors` public (real downstream consumers). Legacy
  `LLMConfiguration` compat surface split to **PKV3-014**. PositronicKit `b7af773`.
- **PKV3-001** — public `LanguageModel` composition protocol; `llmService`→`languageModel`
  public vocabulary; deleted `ExternalLLMProviderRegistry`/`ProviderFactoryRequest`. PositronicKit
  `3a58617`.
- **PKV3-009** — new public `PKUtilities` target (depends only on `PKShared`): observability,
  async/pipeline helpers, filesystem tools relocated out of `PKShared`. PositronicKit `8c89069`.
- **PKV3-011** — every provider target (`PKOpenAIProvider`, `PKOpenRouterProvider`,
  `PKOllamaProvider`, `PKAnthropicProvider`, `PKFoundationModelsProvider`) compiles with zero
  `import PositronicKit`; `LanguageModel` relocated to `PKShared`. PositronicKit `54349bc`.
- **PKV3-008** — structured, payload-safe per-turn warnings when a provider ignores/coerces
  tools/tool-choice/response-format/generation-parameters; published
  `docs/ProviderCapabilityMatrix.md`. PositronicKit `332341d`.

Track 1 (`codex/pkv3-track1`, 8 commits) had been complete since before Track 2/3 merged but sat
unmerged; discovered via `git log` audit 2026-07-13 and merged into the by-then-integrated Track
2+3 `main` as `347e554`. Two real conflicts (both modify/delete: `Conversation.swift` and
`ContextManagerMockingTests.swift`, already deleted by Track 3's renames — resolution kept them
deleted); ~250 files auto-merged (mostly the `PKUtilities` module-split file moves).
`swift build`/`swift test` clean post-merge, 963/963 (167 suites). `make verify`'s docs gate
fails on a pre-existing DocC comment bug from Track 3's PKV3-012 (confirmed already broken on
`main` before every merge in this batch — not introduced by any of this integration work).

### Regressions / red gate (PKFIX)

No open regressions.

| ID | Title | Priority | Triage |
|----|-------|----------|--------|
| _(none)_ | | | |

### Facade redesign (PKFAC-001…009)

Filed 2026-07-09 from a user-driven brainstorm; design in
[`specs/2026-07-09-positronickit-facade-redesign.md`](../specs/2026-07-09-positronickit-facade-redesign.md).
Ground-up redesign of the `PositronicKit` public entry point: `struct` → long-lived `final class`
configuration owner that vends managers/handles through a named operation ladder (one-shot →
Conversation → TimelineManager → AgenticRuntime → raw), grouped `Configuration`, and provider
convenience inits relocated to their provider targets. **Supersedes the discarded PKCLEAN-012**
(additive bootstrap ladder on the old struct facade); its facade-owned `AgentInstanceManager`
decision is carried into PKFAC-006. **Status check 2026-07-09:** two tickets in this series turned
out already implemented ahead of filing — **PKFAC-003** (provider inits already live in their
provider targets, core references zero concrete providers) and **PKAPI-008** (grouped-init
`toolApprovalGate` already wired, commit `97e6c68`) are both marked Done/wontfix in place. PKFAC-002
re-scoped down to just collapsing the flat 16-parameter init into one `Configuration` struct (the
grouped structs + approval gate already exist). **Current delivery phase excludes downstream
consumer migration** — PKFAC-008 delayed 2026-07-09; core lands and stabilizes first. **PKFAC-001
closed (structural spine, package commit `a8c84b4`); PKFAC-003 and PKAPI-008 closed (both already
implemented ahead of filing) — all three archived 2026-07-10, which unblocks the rest of the
series.** **Completed delivery:** PKFAC-001…007 and PKFAC-009 are archived as done; PKFAC-002
closed 2026-07-10 (commit `e5147e4`). **PKFAC-008 closed 2026-07-11** — see closed-batches note
below. **PKFAC series complete.**

| ID | Title | Priority | Triage |
|----|-------|----------|--------|
| _(none — all PKFAC tickets closed)_ | | | |

### Stable-release audit (PKCLEAN-005…010)

Surfaced by a four-track release-readiness audit on 2026-07-08 (flakiness/concurrency,
loop auditability, dead/redundant code, test coverage). Core orchestration and PKPrompt
are release-ready (901 tests); the audit found real concurrency races, nondeterministic
prompt content, silent audit-trail gaps, unreferenced code, and untested critical
surfaces. PKFLAKE-003/004/005/006 (concurrency/robustness), PKCOV-002/003/004 (coverage),
and the full PKLOG observability batch (PKLOG-001/002/003/004) are closed, as are
PKCLEAN-001/005/006/008/009 (Phase 6a) and PKCLEAN-007 (Phase 6b, 2026-07-09) — see the
closed-batches note below. **PKCLEAN-010 discarded (2026-07-10)** — see the closed-batches note below.

| ID | Title | Priority | Triage |
|----|-------|----------|--------|
| _(none — all PKCLEAN-005…010 tickets resolved)_ | | | |

### User architecture-concerns pass (PKCLEAN-011…013)

Filed 2026-07-09 from a user-driven review of five architecture concerns
(`HealthCheckable`, `ToolOutputParser`, `TurnInspecting`/`ChatTurnPlugin` overlap, facade
runtime-bootstrap scope, tools-by-workspace grouping). Confirmed against the code graph:
`HealthCheckable` and `ToolOutputParser` are both fully dead (zero conformers/callers —
folded into PKCLEAN-008 and filed as PKCLEAN-010 above); the other three are real but
narrower than first read (design seams that need a documented decision, not a bug fix).

**PKCLEAN-011/013 closed (Phase 7, 2026-07-09); PKCLEAN-012 discarded** — see the closed-batches note below.

| ID | Title | Priority | Triage |
|----|-------|----------|--------|
| _(none — all PKCLEAN-011…013 tickets resolved)_ | | | |

**PKCLEAN-012 discarded (2026-07-09):** superseded by the facade-redesign series (PKFAC-001…009
above); its facade-owned `AgentInstanceManager` and grouped-init `toolApprovalGate` decisions were
carried into PKFAC-006 / PKFAC-002. Archived.

### Swift API Design Guidelines audit (PKAPI series)

Filed 2026-07-09 from a user-supplied external review checked against Swift API Design
Guidelines. All findings re-verified against source before filing; one finding (the
review's "1d" — that `Prompt.makePromptNode()` forces conformers to understand the
internal `PromptNode` IR) was **rejected**: `Prompt+makePromptNode.swift:3-13` already
provides a default implementation that walks `body` and lowers to the IR automatically,
so conformers never need to touch `PromptNode` directly. Everything else confirmed.
Concentrated in three areas: the tool-execution boundary (`Tool`/`WorkspaceProtocol`/
`ToolApprovalGate`/`LLMToolDefinition`), `ChatEvent`/reasoning-terminology fragmentation,
and provider/configuration parameter ergonomics. **Suggested execution order:** PKAPI-001
(tool boundary, touches the most call sites) → PKAPI-004 (`ChatEvent`, also high-touch) →
PKAPI-003 (reasoning terminology) → PKAPI-007/008 (provider/config) → PKAPI-002/005/006/009
(smaller renames) → PKAPI-010/011 (cosmetic/docs, no rush).

**Second sweep (2026-07-09, PKAPI-012…014):** four parallel discovery agents audited the
remaining targets (PKPrompt, PKShared non-Tools, PositronicKit runtime, provider
packages + PKTestSupport) for the same weakness patterns. Verified survivors:
session/timeline terminology drift, undocumented `dryRun` flags, untyped workspace
metadata, plus a much larger missing-docs inventory folded into PKAPI-011. Rejected on
verification: provider convenience-init "inconsistency" (the differing first-parameter
labels are deliberate cross-provider disambiguators; FoundationModels documents its shape
explicitly), `PromptJournal.reset(hard:)` "undocumented" (it is documented — downgraded
to a call-site-clarity note in PKAPI-013), Mock-vs-spy naming pedantry, and
`ToolCallFormat` case-style (moot — PKCLEAN-007 removes those cases). Notably clean:
PKPrompt's DSL surface had zero structural findings.

| ID | Title | Priority | Triage |
|----|-------|----------|--------|
| _(none — PKAPI-002/006/014/015 all closed; see closed-batches note)_ | | | |

### Second deepening pass (PKDEEP2 series)

Surfaced by a second `/improve-codebase-architecture` run on 2026-07-08 (report reviewed;
candidates 1 and 2 investigated by dedicated discovery agents). PKDEEP2-001 folds the
PKARCH-001 chat-turn split (the same shallow-helper pattern PKDEEP-003 removed from
ToolRouter; all types internal, zero downstream references). The prompt-history
investigation **rejected** the one-shared-diff-engine framing (stable-prefix walk is
runtime-only; PKPrompt's diff is cache-policy-partitioned — PKDEEP-004's conclusion holds)
but found a real bug (PKDEEP2-002: `publicJournalDiff` leaks stable/volatile IDs into
`SemiStable`-named fields, misleading Yakamoz's journal inspector) and two duplicated,
divergent primitives (PKDEEP2-003: compaction thresholds ×2, section fingerprints with
different hash inputs that can make the two systems disagree on the same prompt).
**PKDEEP2 series complete.** All three tickets closed: 002 (bug, Phase 1), 001 (fold,
2026-07-09), 003 (shared core, 2026-07-09) — see the closed-batches note below.

| ID | Title | Priority | Triage |
|----|-------|----------|--------|
| _(none — all PKDEEP2 tickets closed)_ | | | |

### Cleanup follow-ups (PKCLEAN series)

Surfaced by a `cleaning-up-codebases` audit on 2026-07-08. The audit found the source
exceptionally clean (the PKDEEP series had already removed the hypothetical seams and
pass-through modules); these are the residual T3/T4 items the deepening did not cover.
PKCLEAN-001 (file split) is closed — see the closed-batches note below.

PKCLEAN-002/003/004 closed (Phase 6b, 2026-07-09) — see the closed-batches note below.

| ID | Title | Priority | Triage |
|----|-------|----------|--------|
| _(none — PKCLEAN-014 closed 2026-07-10, see closed-batches note)_ | | | |

### Test-fidelity & contract coverage (PKTEST series)

PKTEST-1/2/3 closed (2026-07-07): outcome-shape contract tests pin both leaf-scalar (`.string`)
and `@Schemable` object-schema (`.dictionary`) `SidecarResult.outcome .value` shapes, plus
`null`→`.declined`, missing/wrong key→`.failed`, `Codable` round-trip. The synthetic-tool stream
rewriter now preserves non-synthetic tool calls in mixed chunks (was silently dropping them).
The strict-mode + optional-`required` conflict (root cause of Yakamoz SID-3) is fixed:
`containerSchema(for:)` now ensures every payload property is in `required` and
`additionalProperties: false` is present under `strict: true`. `make verify` green (900 tests /
157 suites).

No open PKTEST tickets remain.

### Deepening opportunities (PKDEEP series)

Surfaced by `/improve-codebase-architecture` on 2026-07-07: seven candidates reviewed in
an HTML report (shallow pass-through modules, abandoned seams, duplicated assembly frames).
PKDEEP-007 is a cross-cutting audit and closes when its child tickets (PKDEEP-001/002/003)
resolve. **Suggested research execution order:** 004 (larger, may block on PKPrompt→PKShared
dependency rule) → 003 (re-litigates PKARCH-002) → 005 (standalone) → 006 (standalone) → 007
(closes after 002/003 settle).

PKDEEP-001 research + impl closed (2026-07-08): collapsed the 10 pass-through `PromptAssemblyStage`
structs, `PromptAssemblyContext` actor, `PromptAssemblyEvent` enum, and `Pipeline` usage into a
direct `[any Prompt]` build via `buildSections` + `withLogging`. `overridePipeline` → `customSections`
seam. Dead `assemblyPipeline` params removed from `ChatEngine.execute`/`TurnPreparer.prepareSession`.
Net -285 lines. `make verify` green (898 tests / 157 suites). Commit `d457bd4`.

PKDEEP-002 research + impl closed (2026-07-08): collapsed `TimelineLifecycleService` and
`WorkspaceAttachmentService` back into `TimelineManager` as `private extension` files
(`TimelineManager+Lifecycle.swift`, `TimelineManager+Attachments.swift`). The 9-method
`TimelineCache` protocol, `FakeTimelineCache` test fake, and three isolation test files are deleted.
All `await cache.cacheX()` hops collapse to synchronous in-actor dict access. `ContextManager`
reverts from `package` to `internal`. `RuntimeToolPolicyFactory` preserved. 7 unique test cases
ported to actor-level suites. Net -550 lines. `make verify` green (885 tests / 155 suites).
Commit `6c71c60`. PKARCH-003 superseded.

PKDEEP-007 closed (2026-07-08): cross-cutting audit of hypothetical one-adapter protocol
seams. 3 of 4 retired by child tickets: `PromptAssemblyStage` (PKDEEP-001-impl),
`TimelineCache` (PKDEEP-002-impl), `WorkspaceResolutionProvider` (PKDEEP-003-impl).
`TurnInspecting` kept with doc comment ("intentional single-customer extension point").
Real-seam contrast list re-verified: `KeyValueStoreProtocol` (2 adapters),
`EmbeddingServiceProtocol` (3), `LLMStreamClient` (5), `ChatTurnPlugin` (0 current
conformers, designed extension point), `PromptSectionProviding` (1 external). Commit `d92f222`.

**PKDEEP series complete.** All 7 tickets closed (001–007, plus impl tickets).

| ID | Title | Priority | Triage |
|----|-------|----------|--------|
| _(none — all PKDEEP tickets closed)_ | | | |

## Closed batches (details in `archive/`)

Full resolution notes live on each archived ticket file; this list is a pointer, not a record.

- **PKV3-014** (2026-07-13, split from PKV3-007) — deleted the legacy flat `LLMConfiguration`
  initializer and its 18 write-through proxy properties; added
  `activeProviderConfiguration: ProviderConfiguration` as the canonical read-only replacement.
  Migrated all 4 provider adapters, `LLMService`/`LLMService+Config`/`LLMService+Stream`,
  `LLMServiceProtocol+StructuredOutput`, `LLMStreamingStage`, `ChatEngine+TurnPreparation`,
  `PositronicKitExamples`, and ~20 test files (via a new test-only
  `LLMConfiguration.fixture(...)` in `PKTestSupport`). Downstream audit: Monad's `ConfigCommand`
  and Yakamoz's `ProviderSettings` both used the deleted surface — migrated ahead of their pin
  bumps (source-level, verified against their current released pins; Shuttle clean, no usage).
  Also fixed a pre-existing DocC gate blocker found along the way (`Tool.identity`'s doc comment
  had unresolvable symbol links, broken since PKV3-012) — `make verify` is now fully green.
  PositronicKit `07c1dbf` (DocC fix `fc9ce0e`); `swift test` 963/963 (167 suites).
- **PKV3-002 / PKV3-003** (2026-07-13, Track 2 of the v3 vocabulary batch) — **PKV3-002**
  (branch `pkv3-track2-workspace-timeline` commit `e74a742`): renamed the overlapping workspace
  names to explicit roles (`Workspace`, `WorkspaceFactory`, `WorkspaceStore`, `WorkspaceCatalog`/
  `DefaultWorkspaceCatalog`, `WorkspaceResolver`/`DefaultWorkspaceResolver`); `TimelineManager` now
  takes `any WorkspaceResolver` via a designated initializer instead of composing the default stack
  internally; default composition moved to `WorkspaceResolverFactory.makeDefault(...)`; added a
  contract test proving a fully custom resolver drives timeline lifecycle. **PKV3-003** (commit
  `9e5e7fa`): deleted `Conversation`; added `TimelineDriver` (`timelineID`/`send(_:)`/`cancel()`,
  no mutable turn state, no exposed `TimelineManager`) and `PositronicKit.openTimeline(_:)` as pure
  driver construction (no persistence I/O until `send(_:)`); renamed `ObservableConversation` →
  `TimelineController` (`.driver` property), superseding-send behavior preserved and tested. Both:
  `swift build` clean, `swift test` 950/950 (163 suites) on the isolated Track 2 branch. **Merged
  to `main` 2026-07-13** (commit `9c5094e`, on top of Track 3's concurrently-merged `348cc6d`):
  the auto-merge scrambled `TimelineManager`'s initializer cluster into non-compiling
  duplicate/ambiguous overloads (no conflict markers — adjacent-but-mismatched hunks merged
  silently) plus two real conflicts (`TurnBriefingBuilder.swift` + its test, both renamed
  independently by each track). Reconciled by hand: kept `Workspace`/`WorkspaceResolver` (Track 2)
  combined with `TurnBriefingBuilder`/`TimelinePromptJournals` (Track 3); rebuilt the
  `TimelineManager` init set as a public/internal split so the package-internal
  `TimelinePromptJournals` type never leaks into a public signature. Post-merge: `swift build`
  clean, `swift test` 968/968 (165 suites). `make verify`'s docs gate fails on a pre-existing
  DocC comment bug from Track 3's PKV3-012 (confirmed already broken on `main` before this merge —
  not introduced by this reconciliation).
- **PKFAC-008 / PKAPI-014** (2026-07-11) — downstream migration verification found the facade
  construction migration (PKFAC-008) was already complete in all three consumers ahead of this
  ticket (Monad/Shuttle/Yakamoz all on PositronicKit `2.0.0`, using the grouped `Configuration`
  init; Monad already reads `coreChat.agentInstanceManager` directly). Only PKAPI-014's dead
  `workspace.metadata` column/field remained: Monad got a `v10` GRDB migration dropping the
  column (`DatabaseSchema+Migrations.swift`, baseline updated, regression test added; 174/174
  Monad tests pass) and Yakamoz's write-only `WorkspaceReferenceModel.metadataData` was removed
  (`PersistenceModels.swift`); Shuttle confirmed clean via grep. Yakamoz's build was not verified
  this session — an unrelated large in-progress `git merge` (`yak-30-entrypoints`, a
  terminal-workspace-entrypoints branch already superseded by `main`'s independent
  Compose/Inspect-era reimplementation) had to be resolved first, and the subsequent build did
  not finish before the session wrapped up. **Follow-up:** verify Yakamoz build/tests green
  before relying on this merge.
- **PKAPI-015 / PKCLEAN-014 / PKCLEAN-010** (2026-07-10) — batch closed from a worktree. **PKAPI-015**
  (commit `35cce94`): renamed the compose-time seam `TurnInspecting`→`PromptInspecting`
  (`didComposeTurn`→`didComposePrompt`, `TurnInspection`→`PromptInspection`, `turnInspector`→
  `promptInspector`) to name the payload, not just the phase; Yakamoz conformer renamed to
  `SwiftDataPromptInspector` (commit + `make verify` release-gated). **PKCLEAN-014** (commit `1752b75`):
  collapsed `HealthCheckable` to `checkHealth()` + `getHealthDetails()`, dropped the dead
  `getHealthStatus()`. **PKCLEAN-010 discarded** — premise stale: `ToolOutputParser` has a live caller in
  `ToolCallExtractionStage` (registered pipeline stage, YAK-39-guarded, covered by `ToolOutputParserTests`
  + `ToolCallRegressionTests`); not dead code, no change. PK build clean; targeted suites pass. NB: PK
  `main` carries pre-existing unrelated red (`LLMServiceTests` `generateTitle` / schema-backed structured
  output assert a JSON-schema response format that isn't set) — tracked separately, not from this batch.
- **PKFAC-004/005/006/007/009** (2026-07-10) — one-shot APIs, Conversation cursor, AgenticRuntime,
  five-tier facade documentation/examples, and the separate PKObservable module. Integrated on
  PositronicKit `main`; core package verification passed before unrelated working-tree tool API
  changes blocked the later full gate.
- **PKFIX-001 / PKFAC-002** (2026-07-10) — fixed the two pre-existing `LLMServiceTests` structured-output
  failures by registering `NativeJSONSchemaStructuredOutputAdapter` for `.openAI` in the test suite init,
  aligning tests with the production OpenAI contract. Collapsed the `PositronicKit` flat 16-parameter
  initializer into the grouped `PositronicKit(configuration:)` API; made `PersistenceConfiguration` stores
  optional with in-memory defaults; migrated tests/examples to the configuration initializer. `make verify`
  green (948 tests / 163 suites).

- **2026-07-08 open-backlog plan, Phases 1–5** (2026-07-09) — PKFLAKE-001–006, PKDEEP2-001–003, PKCOV-001–004, PKLOG-001–004: correctness/race fixes, concurrency/robustness hardening, provider/embeddings/tool-approval test coverage, turn-loop observability (structured logging, `LogKeys` namespace), and deepening refactors (chat-turn fold into `ChatEngine` extensions; shared prompt-history fingerprint/compaction core). `make verify` green (926 tests / 158 suites, up from an 880-test baseline).
- **2026-07-08 open-backlog plan, Phase 6a** (2026-07-09) — PKCLEAN-001/005/006/008/009: `OpenRouterClient` model-layer file split; deleted `OpenAIEmbeddingService`, `PipelineBuilder`, throwing `assertUniqueIDs`/`CollectionUniqueIDError`; deduped the OpenAI/OpenRouter structured-output adapters into one shared `PKShared` type; inlined `MessageParser`; documented the `PositronicKitExamples` test dependency and confirmed `PKFastEmbed` was already target-only. `HealthCheckable` item split off as PKCLEAN-014 (found a real Monad conformer the ticket's premise had missed). `swift test` green (925 tests / 158 suites after net removals).
- **2026-07-08 open-backlog plan, Phase 6b** (2026-07-09) — PKCLEAN-002/003/004/007: split `TimelinePromptHistory` value types into a sibling file; removed the dead `ToolCallFormat.json`/`.xml` cases (lenient `Codable` fallback to `.openAI`, `ollamaDefaults`→`.openAI`); deleted the deprecated `AnyTool` string-provenance init (zero downstream callers); retired the deprecated `LLMServiceProtocol` composite (facade now takes `any LLMStreamClient & LLMConfigStore & LLMUtilityClient`). All PositronicKit-side only — Monad CLI/config (`MON-PK-1`) and `LLMServiceProtocol` call-site migration (`MON-PK-2`) deferred; Shuttle/Yakamoz gaps noted; release-cut + consumer pin bumps deferred. `make verify` green (924 tests / 158 suites).
- **Phase 7 — user architecture-concerns pass** (2026-07-09) — PKCLEAN-011 (docs-only: cross-referencing docstrings on `TurnInspecting`/`ChatTurnPlugin` clarifying the compose-time vs complete-time seam; naming half superseded by PKAPI-015, commit `a9d85fd`), PKCLEAN-013 (additive `TimelineToolManager.tools(inWorkspace:)`/`toolsGroupedByWorkspace()` read API, commit `82e0707`). PKCLEAN-012 discarded (superseded by the PKFAC facade-redesign series). `make verify` green (926 tests / 158 suites).
- **Phase 8 — Swift API Design Guidelines audit, first batch** (2026-07-09) — PKAPI-001 (unified tool-argument type to `AnyCodable`, typed `parametersSchema`, `canExecute` doc fix, commit `856dfb9`), PKAPI-004 (`ChatEvent` ergonomics: `.executionError` rename, flattened unlabeled cases, `PKError.isBlocked`-derived classification, commit `6516ed5`), PKAPI-007 (labeled `ProviderFactoryRequest` replacing the unlabeled `Factory` 5-tuple, `ModelTier` enum replacing the `useUtilityModel`/`useFastModel` boolean pair, `LLMConfiguration` write-through documented, commit `11531cd`), PKAPI-008 (`toolApprovalGate` threaded through both grouped initializers, commit `97e6c68`). Two stale call sites missed by PKAPI-007's first diff (`MockLLMService`, `UnconfiguredLLMServiceTests`) and one `validate-docs` doc-comment gap fixed before merge/in a follow-up commit. `make verify` green (932 tests / 159 suites).
- **Phase 8 — Swift API Design Guidelines audit, second batch** (2026-07-10) — PKAPI-003 (unified `think`/`thinking`/`reasoning` → `reasoning` across `Message`/`LLMStreamDelta`/`ChatEvent`, wire-format fields untouched, commit `a2a8ad0`), PKAPI-005 (`addPlugin`/`addStage` → `addingPlugin`/`addingStage`; found `getTimeline(id:)` is actually public unlike the ticket's premise, kept as-is and added a pure `timeline(id:)`/`touchTimeline(id:)` pair instead, commit `e8db60e`), PKAPI-009 (`formatToolsForPrompt` → `[AnyTool].formattedForPrompt()`, commit `cb3df9d`), PKAPI-010 (`MemorySavePolicy.preventSimilar` → `.deduplicating`, commit `40f4b49`), PKAPI-011 (documented ~50 previously-undocumented public types across PKShared/PKPrompt/PKTestSupport, commit `9cea1bf`; one `validate-docs` cross-reference fix in a follow-up commit `1d5d5d0`), PKAPI-012 (`saveTimeline`'s `session` param → `timeline`, logger label fix; Monad's conformer still uses the old name, noted for its next pin bump, commit `457ee98`), PKAPI-013 (documented the `dryRun` contract on 4 store protocols + added `PruneDryRunTests`; kept `reset(hard:)` docs-only after finding zero real call sites, commit `7f626af`). Three of these agents hit a mid-task session-limit interruption and were resumed from their existing worktree diffs rather than restarted. `make verify` green (940 tests / 160 suites).
- **JRN 1–5** (2026-07-02) — PromptJournal journaling audit: wired/kept as a public tool, registry eviction + lifecycle tests, Yakamoz journal tab, response-capture seam.
- **PKR 1–15** (2026-07-02) — four-track repo review: int-coercion, streaming-cancellation, cache eviction, OpenRouter attribution, retry-gate tests, error-swallowing, doc drift, mock-budget divergence, plus a low-priority tail.
- **SDC 1–9** (2026-07-03) — sidecar simplification: directive descriptors, structured-output dual-path fix, PartialJSON consolidation, schema property order, priority-directive API.
- **PKFAST-001 / PKEMBED-002 / PKFAST-007 / PKCI-003 / PKDOC-004** (2026-06→07) — embeddings & platform: FastEmbed bridge, Linux/trait MiniLM, transactional model handle, toolchain verification matrix, published support contract.
- **PKREL-001–004** (2026-07-05) — v1 release gate: closed all blockers, API freeze (removed deprecated `PositronicKitCore`/`EmbeddingService`/`TokenEstimator`/`WorkspaceTool`), `CHANGELOG.md`, tagged `1.0.0` and moved consumers to semver pins.
- **PKFAST-005/006** (2026-07-05) — FastEmbed safety hardening: batch UTF-8 lifetime repair, native-shape validation/overflow/panic containment.
- **PKINT-001–007** (2026-07-04→05) — integration hardening: stream-decoding contract, tool-call/tool-result history validation, stream watchdog, `ChatRunRequest`, turn-inspecting send identity, instance reconfiguration (`PositronicKit.reconfigured(...)`).
- **PKSTREAM-001** (2026-07-05) — tool-call delta `id` backfill from `TurnOutputs`'s per-index accumulator instead of forwarding nil OpenAI-style continuation-chunk ids.
- **PKPOST-001–004** (2026-07-05→06) — native `PKAnthropicProvider` and `PKFoundationModelsProvider`; structural `ToolProvenance`/`ToolProviding`; released as `1.1.0`.
- **PKARCH-001–006** (2026-07-06→07) — `LLMServiceProtocol` narrowed into three protocols; `ChatEngine`/`TimelineManager`/`ToolRouter` split into thin coordinators + package-internal services; structured-output adapter seam; storage unbundle.
- **PKTEST-1–3** (2026-07-07) — sidecar outcome-shape contract tests; synthetic-tool stream fix (mixed chunks no longer drop non-synthetic tool calls); OpenAI strict-mode schema fix (root cause of Yakamoz SID-3).
- **PKDEEP series, 001–007 + impl tickets** (2026-07-08) — collapsed five hypothetical one-adapter seams back to their concrete owners: prompt-assembly stages, `TimelineCache`, `ToolRouter` helper split, the embeddings backend tower, and a prompting-helper merge; cross-cutting audit (007) confirmed no more remain (`TurnInspecting` kept as an intentional single-customer extension point).

Status legend: Open / In progress / Done / Delayed / Discarded. Lifecycle + archive rules:
root `CLAUDE.md` ("Ticketing system").

Triage: open tickets carry a `Triage:` line (`needs-triage` / `needs-info` /
`ready-for-agent` / `ready-for-human` / `wontfix`) per `docs/agents/triage-labels.md`. The
legacy `Status:` lifecycle above is retained on existing tickets as a historical record; new
tickets use `Triage:` only.
