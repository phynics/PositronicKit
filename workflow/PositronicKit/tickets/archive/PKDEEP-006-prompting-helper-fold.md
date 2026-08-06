# PKDEEP-006 — Fold the one-caller prompting helpers into their owners

**Priority:** P3
**Type:** Research / architecture-review follow-up (deepening candidate, pairs with PKDEEP-001 and PKDEEP-004)
**Depends on:** none (but lands cleanly only alongside PKDEEP-001 and/or PKDEEP-004)
**Blocks:** none
**Triage:** ready-for-agent
**Status:** Done (research) — promoted to PKDEEP-006-impl

### Summary

Three tiny prompting helpers in `Sources/PositronicKit/Services/Prompting/` each have
exactly one call site and exist purely for that call:
`RenderedPromptProjection` (~56 lines), `RenderedPrompt+Messages` (~37 lines),
`StructuredPromptMetadata` (~53 lines). The last one documents its job as *"keeps
`PromptAssembler` and `TimelinePromptHistory` aligned on the exact hash inputs"* —
duplication enforced by a doc comment, not by the compiler. The candidate is to fold the
first two into a single extension on `RenderedPrompt` (in PKPrompt) and push
`StructuredPromptMetadata` into PKPrompt as a method on `PromptSection` /
`RenderedPrompt.Section` so the convention is enforced by the owning type.

This is the natural pairing ticket for PKDEEP-001 (the prompt-assembly stage collapse
lands in the same directory; doing both in one implementation tranche is recommended
unless research surfaces a reason to split them).

### Current problem (with file:line references)

- `Sources/PositronicKit/Services/Prompting/RenderedPromptProjection.swift` (~56 lines) —
  iterates `prompt.sections`, splits into `.system` / `.context` / `.userQuery` /
  `.chatHistory` buckets. One caller: `RenderedPrompt+Messages`.
- `Sources/PositronicKit/Services/Prompting/RenderedPrompt+Messages.swift` (~37 lines) —
  calls `RenderedPromptProjection` and emits 3 `LLMMessage`s. One caller: `PromptAssembler.prepare`
  / the OpenAI projection path.
- `Sources/PositronicKit/Services/Prompting/StructuredPromptMetadata.swift` (~53 lines) —
  extraction of `PromptSection` fields (`id`, `estimatedTokens`, `priority`, `cachePolicy`,
  `path`, `renderedContent`) into `StructuredNodeMetadata`. Two callers:
  `PromptAssembler.buildStructuredMetadata` and `TimelinePromptHistory`. Doc comment says
  the helper "keeps them aligned by convention".
- `Sources/PositronicKit/Services/Prompting/PromptAssembler.swift:194` — explicit comment
  `// Keep this in sync with TimelinePromptHistory via StructuredPromptMetadata.`

**Deletion test result:**
- Delete `RenderedPromptProjection` → reappears as private `init(prompt:)` body of a single
  struct inside `RenderedPrompt+Messages`. Vanishes.
- Delete `RenderedPrompt+Messages` → reappears as ~30 lines in the single caller
  (`PromptAssembler.prepare` / `TurnPreparer`). Vanishes.
- Delete `StructuredPromptMetadata` → reappears as two copies of the hash-input list in
  `PromptAssembler.buildStructuredMetadata` and `TimelinePromptHistory`. **Reappears in
  two places** — the helper is only load-bearing because of the duplication, not because
  the abstraction earned its keep. The deeper fix is to move the metadata make-up into
  PKPrompt's `PromptSection` / `RenderedPrompt.Section` (which already hold the inputs).

### Research scope

1. **Confirm the one-caller claims.** Grep the workspace for `RenderedPromptProjection`
   and `buildConversationMessages` callers. Expected: one production caller each (plus
   tests if any reference the type by name — `RenderedPromptProjection` has none per the
   review). If a second production caller exists, the fold loses locality — record and
   reconsider.
2. **`StructuredPromptMetadata` two-caller audit.** Confirm
   `PromptAssembler.buildStructuredMetadata` and `TimelinePromptHistory` read the same
   `PromptSection` fields in the same order to produce the same `StructuredNodeMetadata`.
   If yes, the convention is mechanically collapsible into
   `PromptSection.nodeMetadata(renderedContent:)` (or
   `RenderedPrompt.Section.nodeMetadata(...)`). Identify exactly which type holds the
   fields today (`PromptSection` vs `RenderedPrompt.Section` — likely both via bridging).
3. **PKPrompt → PKShared dependency audit.** (Same gate as PKDEEP-004 step 3.) If
   `StructuredNodeMetadata` and the hash input types live in PKShared, the
   `nodeMetadata(...)` method on `PromptSection` would force PKPrompt → PKShared. If
   PKPrompt has no such dependency today and that's a hard rule, the method must live on
   the runtime side and the convention survives — record the constraint and downgrade
   the candidate to "fold 2 of 3 helpers, leave metadata external".
4. **Where should `RenderedPrompt+Messages` live?** Two options:
   - (a) As an extension on `RenderedPrompt` in PKPrompt (`buildMessages()` returns
     `[LLMMessage]` — but `LLMMessage` lives in PKShared; forces PKPrompt → PKShared).
   - (b) As a small extension in `PositronicKit/Services/Prompting/` on
     `RenderedPrompt`, folding `RenderedPromptProjection` into its body.
   Pick based on the dependency audit above. (b) is the safer default.
5. **Test reachability.** Inventory tests for these helpers. Confirm none reference
   `RenderedPromptProjection` by name (so the fold loses zero test coverage). Confirm
   `RenderedPrompt+Messages` is exercised via `PromptAssembler.prepare` /
   `RenderedPrompt.string`-shaped tests, which still pass after the fold.
6. **Pairing decision vs PKDEEP-001 and PKDEEP-004.** Decide one of:
   - Land PKDEEP-006 inside the PKDEEP-001 implementation tranche (the natural pairing —
     same directory, same review).
   - Land PKDEEP-006 alongside PKDEEP-004 (if the metadata push requires PKDEEP-004's
     direction (a) — pushing into PKPrompt — to make sense).
   - Land PKDEEP-006 standalone (only `RenderedPrompt+Messages` + projection fold;
     defer `StructuredPromptMetadata` to PKDEEP-004).
   Recommend the smallest standalone-able slice.

### Acceptance criteria

- [x] One-caller audit for `RenderedPromptProjection` and `RenderedPrompt+Messages`
      recorded.
- [x] `StructuredPromptMetadata` two-caller field-list audit recorded.
- [x] PKPrompt → PKShared dependency status recorded (cross-ref PKDEEP-004 step 3).
- [x] Placement decision for `RenderedPrompt+Messages`: (a) PKPrompt extension **or**
      (b) runtime-side extension with projection folded in. Justified.
- [x] Placement decision for `StructuredPromptMetadata`: PKPrompt method on
      `PromptSection`/`RenderedPrompt.Section` **or** kept runtime-side with documented
      constraint. Justified.
- [x] Test churn stated; coverage delta non-negative.
- [x] Pairing recommendation vs PKDEEP-001 and PKDEEP-004 recorded.
- [x] Final finding: **promote** (`PKDEEP-006-impl`, possibly merged into PKDEEP-001-impl
      or PKDEEP-004-impl) **or reject** (ADR if the convention survives for a
      load-bearing reason — e.g. PKPrompt-keeps-no-PKShared-dependency is a hard rule).

### Research findings (2026-07-08)

#### 1. `StructuredPromptMetadata`: ALREADY DONE

`StructuredPromptMetadata.swift` was deleted by PKDEEP-004-impl (commit `dd7ce01`).
The `nodeMetadata(renderedContent:)` method now lives on `PromptSection` and
`RenderedPrompt.Section` in PKPrompt. Zero references to `StructuredPromptMetadata`
remain in the codebase. This portion of PKDEEP-006 is complete.

#### 2. `RenderedPromptProjection` caller audit: TWO callers (not one)

The ticket claims "one caller: `RenderedPrompt+Messages`". This is **wrong**.
`RenderedPromptProjection` has two callers:

1. `RenderedPrompt+Messages.swift` — `buildConversationMessages()` (returns `[Message]`,
   PKShared type)
2. `Prompt+OpenAI.swift` — `buildMessages()` (returns `[LLMMessage]`, PositronicKit type)

Both create a `RenderedPromptProjection(prompt: self)` and pass it to private helpers
that map the projection fields to their respective message types. The projection logic
(splitting sections into system/context/userQuery/chatHistory buckets) is shared —
`RenderedPromptProjection` earns its keep as a shared helper.

#### 3. `buildConversationMessages()` caller audit: ZERO production callers

`buildConversationMessages()` has zero production callers — only 2 test calls in
`PromptAssemblyTests.swift`. It's a public API that produces `[Message]` (PKShared),
while `buildMessages()` produces `[LLMMessage]` (PositronicKit) and is the actual
production path (3 production callers: `PromptAssembler.prepare` x2, `TurnPreparer` x1).

#### 4. Placement decision: option (b) — runtime-side

`LLMMessage` lives in PositronicKit (`Sources/PositronicKit/Services/LLM/LLMServiceProtocol.swift`),
not PKShared. PKPrompt cannot import PositronicKit (circular dependency). Therefore
`buildMessages()` cannot move to PKPrompt. Both extensions stay in
`PositronicKit/Services/Prompting/`.

`buildConversationMessages()` returns `[Message]` (PKShared), so it could theoretically
move to PKPrompt. But it has zero production callers and the `Message` type is already
accessible from PKPrompt. Keeping both extensions together in one file is the right
locality choice.

#### 5. Test churn

- 2 tests call `buildConversationMessages()` — unchanged (public API preserved)
- 8+ tests call `buildMessages()` — unchanged (public API preserved)
- Zero tests reference `RenderedPromptProjection` by name — no churn
- Coverage delta: zero (no behavioral change, just file consolidation)

#### 6. Pairing decision

PKDEEP-001 (assembly stage collapse) and PKDEEP-004 (StructuredPromptMetadata fold)
are both done. PKDEEP-006 is now a standalone ticket with reduced scope: merge
`RenderedPromptProjection.swift` + `RenderedPrompt+Messages.swift` + `Prompt+OpenAI.swift`
into one file, with `RenderedPromptProjection` as a private struct.

#### 7. Final finding: PROMOTE to PKDEEP-006-impl

Merge the 3 files into one `RenderedPrompt+Messages.swift`:
- `RenderedPromptProjection` becomes a `private struct` within the file
- `buildConversationMessages()` stays (public API, tested)
- `buildMessages()` stays (public API, production path)
- `Prompt+OpenAI.swift` deleted (its content moves into the merged file)
- `RenderedPromptProjection.swift` deleted (its content moves into the merged file)

Net: 3 files → 1 file. `StructuredPromptMetadata` already done by PKDEEP-004-impl.
No public API change. No test churn. No downstream coordination.

### Downstream sync

Research only. Folding helpers is package-internal by default; the public
`RenderedPrompt.string` and `LLMPromptResult.messages` shape are unchanged. If the impl
later exposes a new `RenderedPrompt.buildMessages()` public API at the PKPrompt level,
grep all three consumers and ship via tagged release with consumer pin bumps.