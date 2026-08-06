# PKDEEP-005 — Collapse the four-layer embeddings tower into one deep facade

**Priority:** P3
**Type:** Research / architecture-review follow-up (deepening candidate)
**Depends on:** none
**Blocks:** none
**Triage:** ready-for-agent
**Status:** Done (research) — promoted to PKDEEP-005-impl

### Summary

From the public `EmbeddingServiceProtocol` seam to the native call, the local-embeddings
stack crosses four pass-through layers:
`EmbeddingServiceProtocol` → `LocalEmbeddingService` (validate + delegate) →
`LocalEmbeddingBackend` (2-case enum, switch + delegate) → `MiniLMEmbeddingBackend`
/`NaturalLanguageEmbeddingBackend` (delegate) → `MiniLMEmbedder` (the only deep piece,
281 lines: ABI-version check, native handle lifecycle, batch pointer arena, status-code
dispatch). The deep implementation is buried under three forwarding layers. The candidate
is to collapse `LocalEmbeddingService` + `LocalEmbeddingBackend` +
`MiniLMEmbeddingBackend`/`NaturalLanguageEmbeddingBackend` into a single concrete
`LocalEmbeddingService` that implements `EmbeddingServiceProtocol` directly with a
platform-conditional code path and owns input-budget validation, keeping `MiniLMEmbedder`
as the deep native bridge.

### Current problem (with file:line references)

- `Sources/PositronicKit/Services/Embeddings/EmbeddingServiceProtocol.swift` (~7 lines) —
  the real seam, used by `TimelineManager`, `TimelineArchiver`, `ContextManager`.
- `Sources/PKLocalEmbeddings/LocalEmbeddingService.swift` (~95 lines) — public facade;
  body is `try validate(texts); return try await backend.generateEmbeddings(for: texts)`.
- `Sources/PKLocalEmbeddings/LocalEmbeddingBackend.swift` (~47 lines) — 2-case enum
  (`.naturalLanguage`, `.miniLM(backend)`); each method switches and delegates.
- `Sources/PKLocalEmbeddings/MiniLMEmbeddingBackend.swift` (~51 lines) — wraps
  `MiniLMEmbedder`.
- `Sources/PKLocalEmbeddings/NaturalLanguageEmbeddingBackend.swift` (~38 lines) — wraps
  `NLEmbedding`.
- `Sources/PKFastEmbed/PKFastEmbed.swift` (~281 lines) — `MiniLMEmbedder`, the only deep
  piece.

**Deletion test result:** delete `LocalEmbeddingBackend` enum → complexity reappears as a
single `switch` in `LocalEmbeddingService`. Delete the per-backend wrappers → reappear as
`#if os(macOS)` conditionals inside the service. `MiniLMEmbedder` survives — it's the only
piece holding real depth.

### Research scope

1. **Confirm `LocalEmbeddingBackend` has no second adapter per platform.** Grep the
   workspace for conformers/callers. Expected: only the enum's two cases, constructed by
   `LocalEmbeddingService.init`. If a second backend genuinely varies in production (e.g.
   a future `TFEmbeddingBackend`, an Oak model backend), the enum is a real seam — keep
   it and document. If not, it's a hypothetical seam — collapse.
2. **Platform-conditional audit.** Confirm the only branch driving `LocalEmbeddingBackend`
   is `os(macOS)` vs `os(Linux)` (`LocalEmbeddingService.init` likely conditional on
   `#if os(macOS) ... #else ...`). If yes, the enum's switch is replacing a single
   platform conditional — the deepening uses `#if` directly.
3. **`EmbeddingInputBudget.validate` audit.** Where is input-budget validation
   enforced — only in `LocalEmbeddingService`, or also in each backend? If only in the
   service, the collapse moves it into the unified `LocalEmbeddingService` body. If
   duplicated, consolidate to one place.
4. **`MiniLMEmbedder` direct access.** Grep for callers of `MiniLMEmbedder` outside the
   `MiniLMEmbeddingBackend`. Expected: only `PKFastEmbed` tests and the bridge itself.
   If `LocalEmbeddingService` would now hold a `MiniLMEmbedder` directly on Linux, the
   native-handle lifecycle (init, deinit, batch arena) stays inside `MiniLMEmbedder` —
   `LocalEmbeddingService` only owns it; no native lifecycle code moves.
5. **Test impact.** Inventory existing `PKLocalEmbeddingsTests` and any embeddings tests
   in `PositronicKitTests`. Confirm the test surface is `EmbeddingServiceProtocol` (the
   real seam), not any of the wrapper types. If tests target `LocalEmbeddingBackend`
   directly, those tests must be recast as `LocalEmbeddingService` tests (or deleted).
6. **Trait gating (`MiniLMEmbeddings`).** Confirm `PKLocalEmbeddings` is opt-in on
   Apple via the `MiniLMEmbeddings` trait, default on Linux (per `AGENTS.md` Linux
   section). The collapse must preserve the trait surface so consumer opt-in /
   opt-out is unchanged. Specifically: any public init signatures on
   `LocalEmbeddingService` that downstream consumers (Monad, Shuttle, Yakamoz) call must
   stay byte-identical, or this becomes a release-coordinated change.
7. **Downstream impact.** Grep for `LocalEmbeddingService`, `LocalEmbeddingBackend`,
   `MiniLMEmbeddingBackend`, `NaturalLanguageEmbeddingBackend` across all three
   consumers. Expected: zero (these are internal to the package or the trait). Confirm.

### Acceptance criteria

- [x] `LocalEmbeddingBackend` adapter audit recorded; one-adapter-per-platform confirmed
      or second-adapter surfaced.
- [x] Platform-conditional claim confirmed; `#if os(macOS)` is the only branch.
- [x] `EmbeddingInputBudget.validate` enforcement audit recorded; consolidation target
      identified.
- [x] `MiniLMEmbedder` direct-call grep recorded; handle lifecycle stays in
      `MiniLMEmbedder` (deep bridge unchanged).
- [x] Public init signatures on `LocalEmbeddingService` listed; deepening preserves
      them byte-identical (or names the change for release coordination).
- [x] Test churn stated; test surface is the protocol, not the wrappers.
- [x] Downstream grep clean (or named callers).
- [x] Final finding: **promote** (`PKDEEP-005-impl` — internal-only by default; if a
      public init changes, add a workspace downstream-sync ticket) **or reject** (ADR if
      the multi-layer tower is justified — e.g. if a second backend is genuinely
      planned).

### Research findings (2026-07-08)

#### 1. `LocalEmbeddingBackend` adapter audit: ONE-ADAPTER-PER-PLATFORM CONFIRMED

`LocalEmbeddingBackend` is a 2-case enum (`.naturalLanguage`, `.miniLM(MiniLMEmbeddingBackend)`).
It is constructed only by `LocalEmbeddingService.init`:
- Linux: always `.miniLM`
- macOS default: always `.naturalLanguage`
- macOS with `MiniLMEmbeddings` trait: `.miniLM`

No second adapter per platform. The enum's switch is replacing a single platform conditional.
**Hypothetical seam — collapse.**

#### 2. Platform-conditional audit: CONFIRMED

The only branch driving `LocalEmbeddingBackend` is `#if os(Linux)` vs `#else` (macOS) in
`LocalEmbeddingService.init` (lines 30-57). On macOS, the `MiniLMEmbeddings` trait adds an
additional init. The enum's switch is replacing a single `#if` conditional — the deepening
uses `#if` directly.

#### 3. `EmbeddingInputBudget.validate` audit: SINGLE ENFORCEMENT POINT

Budget validation is enforced only in `LocalEmbeddingService` (lines 69-83). The backends
do NOT validate — they just forward. `MiniLMEmbedder` (in PKFastEmbed) has its own
`inputBudget` enforcement at the native bridge level, but that's a separate layer below
`PKLocalEmbeddings`. The collapse keeps validation in `LocalEmbeddingService` — it's
already there.

`backendInputBudget` accessor always returns `self.inputBudget` — the `MiniLMEmbeddingBackend.inputBudget`
is the same value passed through from `LocalEmbeddingService.init`. Redundant accessor
that simplifies to `inputBudget` after folding.

#### 4. `MiniLMEmbedder` direct-call grep: HANDLE LIFECYCLE STAYS IN `MiniLMEmbedder`

`MiniLMEmbedder` is used only by `PKMiniLMPlatformBackend` (66-line actor in PKFastEmbed
that wraps `MiniLMEmbedder` with error mapping from `PKFastEmbedError` to `EmbeddingError`).
`MiniLMEmbeddingBackend` wraps `PKMiniLMPlatformBackend`. No direct callers outside this
chain except `PKFastEmbedTests` (20 tests testing `MiniLMEmbedder` directly — these are the
deep tests that stay unchanged).

`PKMiniLMPlatformBackend` stays standalone — it's in `PKFastEmbed` (a separate target), adds
real error mapping, and is the right abstraction level isolating the native-handle lifecycle.

#### 5. Public init signatures: BYTE-IDENTICAL

Three public inits on `LocalEmbeddingService` must be preserved:
1. `init(modelDirectory:inputBudget:)` — Linux
2. `init(inputBudget:)` — macOS default (NL backend)
3. `init(miniLMModelDirectory:inputBudget:)` — macOS with `MiniLMEmbeddings` trait

Monad calls `LocalEmbeddingService()` at `MonadServerFactory.swift:239` (uses the default
macOS init). Preserving these signatures means zero downstream coordination.

#### 6. Test surface: PROTOCOL SEAM

- 13 tests in `MiniLMEmbeddingContractTests` — test through `LocalEmbeddingService` (protocol
  seam). **1 test** (`testMiniLMBackendUsesConfiguredBudgetAndPreservesTypedLimitError`, line 126)
  constructs `MiniLMEmbeddingBackend` directly — must be recast to use `LocalEmbeddingService`.
- 7 tests in `NaturalLanguageEmbeddingTests` — test through `LocalEmbeddingService` (protocol
  seam). Never names `NaturalLanguageEmbeddingBackend`.
- 3 tests in `EmbeddingServiceTests` — test through `LocalEmbeddingService` (protocol seam).
- 20 tests in `PKFastEmbedTests`/`PKFastEmbedBatchTests` — test `MiniLMEmbedder` directly.
  **Unchanged.**
- 4 tests in `MockEmbeddingServiceBudgetTests` — test `MockEmbeddingService`. **Unchanged.**
- 16 tests using `MockEmbeddingService` as collaborator. **Unchanged.**

Only 1 test touches a wrapper type directly. Test churn is minimal.

#### 7. Downstream grep: CLEAN

Only 1 downstream reference: `LocalEmbeddingService()` in `MonadServerFactory.swift:239`
(immediately upcast to `any EmbeddingServiceProtocol`). Zero references to any internal
backend type. No coordination needed if public init signatures are preserved.

#### 8. Final finding: PROMOTE to PKDEEP-005-impl

Collapse `LocalEmbeddingBackend` (47 lines) + `MiniLMEmbeddingBackend` (51 lines) +
`NaturalLanguageEmbeddingBackend` (38 lines) into `LocalEmbeddingService`. The unified
service:
- Implements `EmbeddingServiceProtocol` directly
- Uses `#if os(Linux)` / `#if canImport(NaturalLanguage)` / `#if MiniLMEmbeddings`
  conditionals for platform paths
- Holds a `PKMiniLMPlatformBackend` directly on Linux/trait builds (instead of through
  `MiniLMEmbeddingBackend`)
- Inlines the `NLEmbedding` logic directly on macOS (instead of through
  `NaturalLanguageEmbeddingBackend`)
- Owns input-budget validation (already does)
- `MiniLMModelAssets.validate(modelDirectory:)` moves into the MiniLM init paths

Keeps unchanged:
- `PKMiniLMPlatformBackend` (66 lines, PKFastEmbed) — public actor with error mapping
- `MiniLMEmbedder` (281 lines, PKFastEmbed) — the deep native bridge
- `EmbeddingServiceProtocol` (7 lines) — the real seam
- `EmbeddingInputBudget` (PKShared) — the budget type
- `EmbeddingError` (PositronicKit) — the error type

Deletes:
- `LocalEmbeddingBackend.swift` (47 lines)
- `MiniLMEmbeddingBackend.swift` (51 lines)
- `NaturalLanguageEmbeddingBackend.swift` (38 lines)
- `LocalEmbeddingBackendKind` enum (folds into a computed property on `LocalEmbeddingService`)

Test churn: 1 test recast. Net -136 lines (3 files deleted, logic inlined into existing
`LocalEmbeddingService.swift`).

### Downstream sync

Research only. If an implementation later changes a public init on
`LocalEmbeddingService`, all three consumers (Monad, Shuttle, Yakamoz) must be grepped
and the change shipped as a tagged PositronicKit release with consumer pin bumps per
the workspace release flow.