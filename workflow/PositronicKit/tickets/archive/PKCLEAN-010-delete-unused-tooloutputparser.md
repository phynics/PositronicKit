# PKCLEAN-010 — Delete unused `ToolOutputParser` fallback parser

**Priority:** P3
**Type:** Refactor (dead-code removal)
**Depends on:** —
**Blocks:** —
**Triage:** wontfix
**Status:** Discarded (2026-07-10) — premise stale, do not delete.

**Resolution:** The ticket's core claim ("zero callers, confirmed via the code graph") is **factually
wrong** — the code graph was stale. `ToolOutputParser.parse(from:)` has a live, load-bearing caller at
`Sources/PositronicKit/Services/Chat/Stages/ToolCallExtractionStage.swift:54`, the fallback text-parsing
path for models that emit tool calls as raw text instead of structured tool-call deltas. That stage is
registered in the live pipeline (`ChatTurnPipelineBuilder.swift:18`, runs every turn), the fallback is
deliberately guarded by `!context.availableTools.isEmpty` (a YAK-39 security hardening so stray
`<tool_call>` markers can't bypass approval gates), and the parser is covered by dedicated tests
(`ToolOutputParserTests`) plus regression tests (`ToolCallRegressionTests` — XML tool-call parsing and
fenced-truncated-JSON recovery). This is not a "wire it or cut it" case; it is fully wired, tested, and
hardened. No code change. If the PKCLEAN-007 non-native-tool-calling direction is ever revisited, that
is a fresh feature decision, not a dead-code deletion.

### Summary

`Sources/PositronicKit/Utilities/ToolOutputParser.swift` implements a full fallback
tool-call parser for models that emit tool calls as raw text instead of structured
provider tool-call objects: pipe-delimited (`<|tool_call_begin|>`, Qwen-style),
XML-tagged (`<tool_call>...</tool_call>`), and markdown-code-block forms, plus lenient
JSON repair for truncated/trailing-comma fragments.

Its entry point, `ToolOutputParser.parse(from:)`, has **zero callers** anywhere in the
package (confirmed via the code graph — `callers: 0` on both the type and every method
inside it, and no call site in `LLMStreamingStage`, `ChatEngine`, or any provider
adapter). It is fully built but never wired into the turn loop or any provider.

This is a genuine "wire it or cut it" case, not a refactor — it doesn't overlap with
PKCLEAN-007 (`ToolCallFormat.json`/`.xml`, a *persisted config enum* that's also unread,
but a different, narrower surface: a stored preference vs. a parsing utility). Both
should probably be decided together since they point at the same unfinished feature
(support for non-native-tool-calling models), but PKCLEAN-007 already has a **recorded
decision to remove** — that decision context is directly relevant here.

### Implementation Requirements

- [ ] Re-confirm zero callers via `grep -rn "ToolOutputParser" PositronicKit/Sources
      PositronicKit/Tests` and across Monad/Shuttle/Yakamoz (downstream-sync habit,
      even though this type isn't `public` beyond the package — check for reflection/
      string-based dynamic use, there shouldn't be any).
- [ ] Given PKCLEAN-007's decision to remove non-OpenAI-style tool-calling support,
      delete `ToolOutputParser.swift` and its dedicated tests (if any exist under
      `Tests/PositronicKitTests/`).
- [ ] If the PKCLEAN-007 decision is revisited toward "(b) wire the formats," re-evaluate
      this ticket too — the two should not diverge (don't wire `ToolCallFormat.json`
      without also wiring the parser that would consume it, or vice versa).

### Acceptance Criteria

- [ ] `ToolOutputParser` and any orphaned tests removed, or an explicit call site added
      wiring it into the streaming/tool-call pipeline — not left dead.
- [ ] `make verify` green; CHANGELOG updated.
