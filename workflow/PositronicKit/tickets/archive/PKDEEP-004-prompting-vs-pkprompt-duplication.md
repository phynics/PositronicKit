# PKDEEP-004 — Collapse PositronicKit/Prompting vs PKPrompt/PromptAssembly duplication

**Priority:** P3
**Type:** Research / architecture-review follow-up (deepening candidate)
**Depends on:** none
**Blocks:** none (loosely interacts with PKDEEP-001 and PKDEEP-006)
**Triage:** ready-for-agent
**Status:** Done (research) — promoted to PKDEEP-004-impl

### Summary

Two prompt-assembly/history systems coexist with overlapping vocabulary:
`PKPrompt/PromptAssembly/` + `PKPrompt/Journal/` (the canonical prompt IR / render /
journal subsystem) and `PositronicKit/Services/Prompting/` (a runtime-side pipeline
framework, assembler, projection, history optimizer, structured-metadata bridge, and a
540-line `TimelinePromptHistory`). The runtime side re-exposes five
`PromptAssembler.Options` fields (`overridePipeline`, `tokenBudget`, `compressor`,
`structuredDiff`, `structuredExecutor`) that re-package PKPrompt types (which already do
the work). `StructuredPromptMetadata` documents its job as "keeps `PromptAssembler` and
`TimelinePromptHistory` aligned on the exact hash inputs" — duplication enforced by a
doc comment, not by the compiler. Two "prompt history" subsystems (`TimelinePromptHistory`
540L runtime-side, and `PromptJournal`/`PromptJournalDiffer` PKPrompt-side) coexist with
overlapping vocabulary (`PromptHistoryUpdate`, `PromptJournalDiff`, `stablePrefixCount`,
`didCompact`).

The candidate is to either push assembly end-to-end into PKPrompt (so PKPrompt owns
`LLMPromptRequest → RenderedPrompt`) or strip the runtime-side pipeline framework back to
a plain ordering of section constructors over PKPrompt types — eliminating the duplicated
hash-input convention by moving metadata into PKPrompt's `PromptSection` /
`RenderedPrompt.Section`.

### Current problem (with file:line references)

- `Sources/PositronicKit/Services/Prompting/PromptAssembler.swift:66-98` — the
  runtime-side assembler threads 5 options that re-expose PKPrompt's own compression /
  diff / executor machinery.
- `Sources/PositronicKit/Services/Prompting/PromptAssembler.swift:186-201` —
  `buildStructuredMetadata` constructs per-section metadata with the comment
  `// Keep this in sync with TimelinePromptHistory via StructuredPromptMetadata.`
- `Sources/PositronicKit/Services/Prompting/StructuredPromptMetadata.swift` (~53 lines)
  — the helper whose doc comment carries the "keep aligned" convention.
- `Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift` (~540 lines) —
  runtime's prompt-history primitive; vocabulary overlaps `PKPrompt/Journal/` (`PromptJournal`,
  `PromptJournalDiffer`, `PromptJournalDiff`, `stablePrefixCount`, `didCompact`).
- `Sources/PKPrompt/PromptAssembly/`, `Sources/PKPrompt/Journal/`, `Sources/PKPrompt/Compression/`
  — the canonical PKPrompt side.
- `Sources/PositronicKit/Services/Prompting/RenderedPromptProjection.swift` (~56 lines,
  one caller) and `RenderedPrompt+Messages.swift` (~37 lines, one caller) — see
  PKDEEP-006.

**Deletion test result:** the bridge layer (projection, messages, options re-exposure,
stage framework per PKDEEP-001) is non-load-bearing if PKPrompt owns end-to-end assembly.
The `TimelinePromptHistory` ↔ `PromptJournal` *interaction* is load-bearing (real
caching/diff semantics) — the friction is the bridging code, not either side.

### Research scope

1. **Confirm the comment-enforced invariant is real.** Grep for callers of
   `StructuredPromptMetadata.makeNodeMetadata`. Confirm exactly two callers
   (`PromptAssembler.buildStructuredMetadata` and `TimelinePromptHistory`). If both
   compute the same hash inputs from the same `PromptSection` fields, the metadata logic
   belongs on `PromptSection` (or `RenderedPrompt.Section`) itself. Identify which
   `PromptSection` fields are read (expected: `id`, `estimatedTokens`, `priority`,
   `cachePolicy`, `path`) and confirm `RenderedPrompt.Section` already holds them.
2. **Decide the deepening direction — two options, pick one:**
   - **(a) Push assembly end-to-end into PKPrompt.** PKPrompt gains an entry point that
     accepts a runtime-supplied ordered list of section constructors (or a thin
     `LLMPromptRequest`-shaped struct passed in via a package boundary) and returns
     `RenderedPrompt`. Runtime keeps only "which sections, in what order" — a list, not a
     framework. Pro: deepest. Con: PKPrompt grows a new entry point that must not depend
     on runtime types (`LLMPromptRequest` lives in PKShared — confirm this is acceptable
     via PKPrompt → PKShared dependency; if PKPrompt currently has no PKShared dependency,
     this direction is blocked).
   - **(b) Strip the runtime-side framework over PKPrompt types.** Drop
     `PromptAssemblyStage`/`Context`/`Event` (covered by PKDEEP-001), drop
     `RenderedPromptProjection`/`+Messages` (covered by PKDEEP-006), keep `PromptAssembler`
     as a plain ordering of section constructors that calls `AssembledPrompt(sections:)`
     and `render()` directly. Pro: smaller change. Con: `StructuredPromptMetadata`
     duplication migrates to PKPrompt only if (a) — under (b) the metadata still lives
     runtime-side and the comment-enforced invariant survives.
3. **PKPrompt → PKShared dependency audit.** Open `Package.swift`; confirm whether
   `PKPrompt` already depends on `PKShared`. `LLMPromptRequest` is in `PKShared`. If
   PKPrompt currently has no PKShared dependency, direction (a) is blocked; record and
   default to (b).
4. **`TimelinePromptHistory` ↔ `PromptJournal` audit.** Identify what
   `TimelinePromptHistory` does that `PromptJournal`/`PromptJournalDiffer` cannot. If the
   delta is "runtime's per-timeline bookkeeping" (timeline id, last-compacted-id, agent
   identity), the runtime-side wrapper is justified and only the *metadata duplication*
   collapses. If the delta is "prompt caching/diff logic duplicated against
   `PromptJournal`", the deepening folds the diff/stable-prefix logic back into
   PKPrompt. Document the delta.
5. **Test reachability.** If PKPrompt owns end-to-end assembly under (a), the assembly
   tests move to `Tests/PKPromptTests/`. Inventory what the runtime-side
   `PromptAssembler*Tests` cover and confirm it's expressible as PKPrompt tests (no
   runtime fixtures required).
6. **Downstream impact.** Grep Monad, Shuttle, Yakamoz for `PromptAssembler`,
   `PromptAssemblyOptions`, `StructuredPromptMetadata`. Confirm expected zero public
   usage (these are package-internal) or identify call sites for coordination.

### Acceptance criteria

- [x] Two-caller claim for `StructuredPromptMetadata.makeNodeMetadata` confirmed; field
      list recorded.
- [x] `PromptSection` / `RenderedPrompt.Section` field audit; fields available for
      `nodeMetadata(...)` method recorded.
- [x] PKPrompt → PKShared dependency status recorded; direction (a) feasibility decided.
- [x] `TimelinePromptHistory` vs `PromptJournal` delta table produced.
- [x] Deepening direction chosen: (a) push end-to-end into PKPrompt **or** (b) strip
      runtime-side framework, with rationale. If (b), confirm
      `StructuredPromptMetadata` duplication is either folded into PKPrompt (contradicting
      the (b) sketch — explain) or accepted as remaining friction.
- [x] Test reachability for the chosen direction documented.
- [x] Downstream grep clean (or named callers).
- [x] Final finding: **promote** (`PKDEEP-004-impl`; may be split into PKPrompt-side and
      runtime-side sub-tickets depending on chosen direction), **or reject** (ADR if
      load-bearing; e.g. if PKPrompt-keeps-no-PKShared-dependency is a hard rule, record
      it so future reviews don't suggest direction (a)).
- [x] Cross-link to PKDEEP-001 and PKDEEP-006 if those land as a coupled tranche.

### Research findings (2026-07-08)

#### 1. Two-caller claim: CONFIRMED

`StructuredPromptMetadata.makeNodeMetadata` has exactly two production callers:

1. `PromptAssembler.buildStructuredMetadata` (`PromptAssembler.swift:212`) — passes
   `PromptSection` + `renderedContent`
2. `TimelinePromptHistory.nodeMetadata(prompt:)` (`TimelinePromptHistory.swift:412`) —
   passes `RenderedPrompt.Section` + `renderedContent`

Both read the same fields (`id`, `estimatedTokens`, `priority`, `cachePolicy`, `path`,
`renderedContent`) and call `StableHash.hash(components:)` with identical inputs:
`[id, String(estimatedTokens), String(priority), String(describing: cachePolicy),
renderedContent]`.

Test callers in `TimelinePromptHistoryTests.swift` (lines 71, 103, 107) use the raw
`makeNodeMetadata(id:estimatedTokens:priority:cachePolicy:path:renderedContent:)`
overload.

#### 2. Field audit: CONFIRMED

Both `PromptSection` (`PromptSection.swift`, PKPrompt) and `RenderedPrompt.Section`
(`RenderedPrompt+Section.swift`, PKPrompt) expose every field needed:
`id`, `estimatedTokens`, `priority`, `cachePolicy`, `path`. A
`nodeMetadata(renderedContent:) -> StructuredNodeMetadata` method is expressible on
either type with no new public fields.

`StructuredNodeMetadata` and `StableHash` are both accessible from PKPrompt:
- `StructuredNodeMetadata` is in `PKPrompt/PromptAssembly/Compression/StructuredCompressionPlan.swift`
- `StableHash` is in `PKShared/Utilities/StableHash.swift` (PKPrompt already depends on PKShared)

#### 3. PKPrompt → PKShared dependency: CONFIRMED, but direction (a) still BLOCKED

PKPrompt **already** depends on PKShared (`Package.swift:52`, 20 `import PKShared`
statements in PKPrompt source files). The ticket's worry at lines 71-72 and 82-83 about
this dependency is misplaced.

However, direction (a) is **blocked for a different reason**: the ticket claims
"`LLMPromptRequest` is in `PKShared`" (line 82) — this is **factually wrong**.
`LLMPromptRequest` is defined at
`Sources/PositronicKit/Services/LLM/LLMServiceProtocol.swift:80`, in the **PositronicKit**
target. PKPrompt cannot import PositronicKit (circular dependency: PositronicKit already
imports PKPrompt). Moving `LLMPromptRequest` to PKShared would require auditing all of
its field types (`ContextFile`, `Memory`, `Message`, `AnyTool`, `WorkspaceReference`) and
potentially cascading them downward — a migration far beyond this ticket's scope, and
architecturally questionable since `LLMPromptRequest` is a runtime-facing request struct,
not a prompt-layer concept.

**Direction (a) is blocked. Default to (b).**

#### 4. `TimelinePromptHistory` vs `PromptJournal` delta

Both sides have genuinely load-bearing semantics the other lacks. This matches the
ticket's "deletion test result" note — the *interaction* is load-bearing, the friction is
the *bridging code* (metadata duplication, `publicJournalDiff` projection, parallel
threshold structs).

**What both do (duplicated):**

| Concern | `PromptJournal` (PKPrompt) | `TimelinePromptHistory` (runtime) |
|---------|---------------------------|------------------------------------|
| Committed base snapshot | `committedBaseSections` | `baseSnapshot: PromptSnapshot?` |
| Append-pressure counters | `appendedMessageCount/Tokens` | identical |
| Compaction thresholds | `PromptJournalCompactionThresholds` (50000/40) | `CompactionThresholds` (50000/40) — identical defaults |
| `shouldCompact` | identical expression | identical expression |
| `recordAppend(messages:)` | identical (delegates to `TokenEstimator`) | identical |
| Produces `PromptJournalDiff` | yes (directly) | yes (via `PromptDiff.publicJournalDiff` projection) |

**What `PromptJournal` does that `TimelinePromptHistory` does NOT (unique to PKPrompt):**

1. Layered journal plan (`PromptJournalPlan`) — base/overlay/volatile layer projection
2. `EmissionMode` (.snapshot / .delta) — snapshot-vs-delta emission policy
3. Hard-reset on stable-content change (`PromptJournalDiffer.hasStableChanges`)
4. Semistable overlay computation (`computeSemiStableOverlay`)
5. Message rendering (`buildMessages()` — XML-tagged journal messages)
6. Three-layer cache-policy semantics (stable→base, semi-stable→overlay, volatile→current-only)

**What `TimelinePromptHistory` does that `PromptJournal` does NOT (unique to runtime):**

1. Per-timeline LRU registry (`TimelinePromptHistoryRegistry`, max 1000 entries, keyed by `UUID`)
2. Positional stable-prefix counting (walks `previous[idx] == current[idx]` by id AND contentHash)
3. `stablePrefixTokens` accounting (token sum of the stable prefix for LLM cache-prefix)
4. `SubtreeDiff` with added/removed node paths (richer than PKPrompt's `StructuredDiffHint` which has only changed+stable)
5. `nextInspectionTurnIndex()` — persisted across `execute()` calls for `TurnInspectionModel` row indexing
6. `structuredDiffHint()` bridge — projects `lastDiff` into PKPrompt's `StructuredDiffHint`
7. `nodeMetadata(prompt:)` bridge — builds `[String: StructuredNodeMetadata]` for compression
8. `PromptDiff.publicJournalDiff` projection — one-way bridge from runtime → PKPrompt
9. Actor isolation (thread-safe, shared across turns)

**Conclusion:** `TimelinePromptHistory` is a justified runtime-side primitive. The delta
is NOT just "per-timeline bookkeeping" — it includes real diff/stable-prefix logic that
`PromptJournal` does not own. The deepening should NOT fold `TimelinePromptHistory` into
`PromptJournal`. Only the *metadata duplication* (`StructuredPromptMetadata`) collapses.

#### 5. Deepening direction chosen: (b) with metadata fold

Direction (b) — strip runtime-side framework over PKPrompt types.

**Ticket correction:** The ticket claims "under (b) the metadata still lives runtime-side
and the comment-enforced invariant survives" (lines 78-79). This is **wrong**. The metadata
method can be folded into PKPrompt even under (b) because:

1. `StructuredPromptMetadata.makeNodeMetadata` only reads `PromptSection` /
   `RenderedPrompt.Section` fields (both PKPrompt types)
2. It calls `StableHash.hash(components:)` (PKShared, already a PKPrompt dependency)
3. It returns `StructuredNodeMetadata` (PKPrompt type)
4. It has **zero** runtime dependencies

The implementation should add `func nodeMetadata(renderedContent: String) ->
StructuredNodeMetadata` on both `PromptSection` and `RenderedPrompt.Section` in PKPrompt,
delete `StructuredPromptMetadata.swift`, and update both callers to use the PKPrompt method
directly. The comment-enforced invariant becomes a compiler-enforced method on the type that
owns the fields.

**What stays runtime-side (justified):**

- `PromptAssembler` (219 lines) — thin stateless section-ordering enum. After PKDEEP-001,
  it's just `buildSections` (runtime-specific section ordering) + `assemblePrompt`
  (pass-through to `AssembledPrompt` + `render()`) + `buildStructuredMetadata` (being folded).
- `PromptAssemblyOptions` (45 lines) — plain options bag, no logic. Pass-through to PKPrompt
  compression types + runtime-specific section override + logger.
- `TimelinePromptHistory` (540 lines) — justified separate from `PromptJournal` (see delta table above).
- `RenderedPromptProjection` (56 lines) + `RenderedPrompt+Messages` (37 lines) + `Prompt+OpenAI`
  (100 lines) — covered by PKDEEP-006.

#### 6. Latent bug found

`TokenBudget.defaultNodeHash(for:)` (`TokenBudget.swift:245-252`) hashes
`[id, estimatedTokens, priority, cachePolicy]` — **omits `renderedContent`** that
`StructuredPromptMetadata.makeNodeMetadata` includes. If a caller ever supplies
`TokenBudget` with `nodeMetadata: [:]` (empty), the structured-compression cache key
won't invalidate on content-only changes. In practice, `PromptAssembler` always builds
full metadata, so the fallback rarely fires — but the inconsistency should be fixed as
part of the impl ticket by aligning `defaultNodeHash` inputs with the new
`nodeMetadata(renderedContent:)` method.

#### 7. Test reachability

After folding `nodeMetadata` into PKPrompt, the `StructuredPromptMetadata` test cases in
`TimelinePromptHistoryTests.swift` (lines 71, 103, 107) should move to `PKPromptTests`
and test the `PromptSection.nodeMetadata(renderedContent:)` /
`RenderedPrompt.Section.nodeMetadata(renderedContent:)` methods directly. The runtime-side
tests that verify the callers (`PromptAssembler` and `TimelinePromptHistory`) continue to
exist but call the PKPrompt method.

#### 8. Downstream impact: CLEAN

Zero direct usages of any of the 9 symbols (`PromptAssembler`, `PromptAssemblyOptions`,
`StructuredPromptMetadata`, `TimelinePromptHistory`, `TimelinePromptHistoryRegistry`,
`PromptHistoryUpdate`, `PromptDiff`, `RenderedPromptProjection`, `buildMessages`) in
compiled code across Monad, Shuttle, or Yakamoz. The only hits are:
- 1 Yakamoz test comment naming `TimelinePromptHistory` (descriptive prose, no API touch)
- 2 Monad doc examples calling `prompt.buildMessages(budget: 8000)` (stale legacy docs,
  wrong signature — candidates for a doc refresh independent of this ticket)

No downstream coordination needed for the impl ticket.

### Downstream sync

Research only. If direction (a) is later chosen and exposes a new PKPrompt public entry
point, downstream consumers (Monad, Yakamoz) may grow new direct calls — coordinate a
PositronicKit release and consumer pin bumps per the workspace release flow.