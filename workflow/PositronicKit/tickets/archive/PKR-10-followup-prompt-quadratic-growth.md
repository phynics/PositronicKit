# PKR-10 — `synthesizeFollowUpPrompt` re-serializes the whole prompt each tool round-trip (O(n²))

**Status:** Done
**Severity:** 🟡 Low (perf/memory in long agentic loops)
**Repos:** PositronicKit
**Source:** PositronicKit review 2026-07-02

## Problem

Each `.continueWith` iteration of the chat loop calls `synthesizeFollowUpPrompt`
(`ChatEngine.swift:434-467`), which appends a new section to `basePrompt.sections` and re-joins
the *entire* sections array into a fresh string (`:464`) every turn. With caller-supplied
`maxTurns` (default 5, unbounded upstream — e.g. Shuttle shard runs), long tool-call loops do
O(n²) string work and retain every prior synthesized section for the loop's lifetime. Separate
from `TimelinePromptHistory` compaction, which doesn't shrink `renderedPrompt.sections`.

Also in this area: `ChatEngine.Constants.maxHistoryTokens`/`historyTokenBuffer`
(`ChatEngine.swift:55-56`) are dead duplicates of the live values in
`PromptHistoryOptimizer.swift:7-9` — delete or make one the source of truth while here.

## Suggested direction

Confirm realistic turn counts; if dozens of turns are plausible, build follow-up prompts
incrementally (append-only string or lightweight representation) instead of re-joining all
sections per turn. Remove the dead constants.

## Resolution (2026-07-04)

`synthesizeFollowUpPrompt` (`ChatEngine.swift`) now appends the newly-synthesized section's
rendered text onto the already-rendered `basePrompt.string` instead of re-joining every prior
section from scratch each `.continueWith` turn, eliminating the O(n²) string work across long
tool-call loops. `sections`/`sectionsByID` accumulation is unchanged.

Deleted the dead `ChatEngine.Constants.maxHistoryTokens`/`historyTokenBuffer` — grepped the whole
repo and confirmed their only usage was their own declaration; `PromptHistoryOptimizer.swift`'s
values were already the live ones.

Added a multi-turn test (`TurnInspectingTests.swift`) driving 6 tool-call turns and asserting, at
every turn, that the incrementally-built `rendered.string` is byte-identical to a full from-scratch
section re-join. Full suite green.
