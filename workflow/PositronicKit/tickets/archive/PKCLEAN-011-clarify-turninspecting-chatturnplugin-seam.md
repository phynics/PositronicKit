# PKCLEAN-011 — Clarify the `TurnInspecting` / `ChatTurnPlugin` seam

**Priority:** P3
**Type:** Docs / naming clarity
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `a9d85fd`) — added cross-referencing docstrings to
`TurnInspecting` and `ChatTurnPlugin` clarifying the compose-time (pre-response, read-only,
single optional inspector) vs complete-time (post-LLM, read-write, ordered plugin list)
distinction; tightened `CompletedTurn`'s read-only-snapshot comment. Docs-only, no behavior
change. `make verify` green (926 tests / 158 suites). The naming half of this ticket's remit is
superseded by PKAPI-015 (see the update note below).

**Update (2026-07-09):** the docs-only work below landed. The naming half of this ticket's remit
("consider whether `TurnInspecting` would be clearer named...") is superseded by
[PKAPI-015](PKAPI-015-turninspecting-promptinspecting-rename.md), which renames
`TurnInspecting` → `PromptInspecting` (a follow-up user decision after this ticket closed docs-only).
This ticket's core keep-two-protocols finding still stands — PKAPI-015 renames, does not merge.

### Decision (2026-07-09) — **keep two protocols, docs-only; correct the ticket's premise**

An Opus design review (dispatched per the user's "ask opus for a better pattern") independently
weighed unify-vs-separate and concluded the two-protocol shape is correct — but found the ticket's
own framing factually wrong, which is *why* the separation is obviously right once stated:

**The two hooks do not both fire "around turn completion." They fire in different phases:**

| | `TurnInspecting.didComposeTurn` | `ChatTurnPlugin.afterTurn` |
|---|---|---|
| Fires | **before** the LLM runs (prompt-assembly time) — `ChatEngine+TurnLoop.swift:243-289` | **after** the turn completes — `ChatTurnFollowUpPolicy.swift:35` |
| Payload | `TurnInspection`: rendered prompt, sent messages, journal diff — **no response yet** | `CompletedTurn`: `fullResponse`, turn count, model — **the output** |
| Cardinality | single optional `turnInspector` | ordered list `chatTurnPlugins` |
| Power | read-only (`-> Void`) | read-write (`-> [LLMMessage]`, can drive a follow-up turn) |
| Real conformers | 1 (Yakamoz `SwiftDataTurnInspector`) | 0 (designed extension point) |

Yakamoz's conformer confirms the phase gap in code: `didComposeTurn` persists a row with
`responseData: nil` (no response exists yet) and fills the response in *later* via a separate
`.streamCompleted` path — it never uses `afterTurn`. Payloads overlap only on correlation keys
(timelineId/agentInstanceId/model/turn ordinal); the substantive data is disjoint (input side vs.
output side).

**Rejected: rename `TurnInspecting → TurnObserving`** — it optimizes the wrong axis (read/write)
when the load-bearing distinction is *when they fire* (compose-time vs. complete-time).
`didComposeTurn` is already an accurate name.

**Rejected: unify into one protocol** — disjoint phases/payloads (a merged type hands every
conformer a method it fires in the wrong phase with data it lacks), cardinality mismatch (one
optional sink vs. an ordered list whose returns compose), and the partial-conformance trap (dead
no-op method in every observe-only type's witness table / autocomplete).

**Action:** docs-only, no behavior change. Add cross-referencing docstrings to both protocols
stating the compose-time-vs-complete-time distinction explicitly and pointing at each other; note
`TurnInspection` is the pre-response snapshot; tighten `CompletedTurn`'s "read-only snapshot"
comment (plugins mutate the loop via the return value). Keep the "do not generalize without a
second adapter" scope-discipline note but clarify it's about *this* protocol's surface, not a
reason to merge. `make verify` green.

### Summary

Two extension protocols both fire around turn completion and read as the same seam from
outside the package:

- `TurnInspecting.didComposeTurn(_:)` (`Sources/PositronicKit/Protocols/TurnInspecting.swift:12`)
  — read-only observation hook, fed a `TurnInspection` prompt/journal snapshot. Single
  optional instance per facade (`turnInspector`).
- `ChatTurnPlugin.afterTurn(_:)` (`Sources/PositronicKit/Protocols/ChatTurnPlugin.swift:33`)
  — read-write hook fed a `CompletedTurn`, can return `[LLMMessage]` to inject and trigger
  a follow-up turn. A list of plugins per facade (`chatTurnPlugins`).

They are not actually duplicative — one observes, one can drive another turn — but the
naming and shape (both "protocol conforming type registered on the facade, called once
per completed turn") don't signal that distinction to a new reader. The `TurnInspecting`
docstring itself already flags awareness of this risk: *"Do not generalize without a
second adapter"* — i.e. a past decision *not* to merge these was made deliberately but
left undocumented as to why.

### Implementation Requirements

- [ ] Write up the actual distinction (observation vs. turn-loop control; single
      inspector vs. plugin list; snapshot type differences) as doc comments on both
      protocols, cross-referencing each other explicitly ("see also `ChatTurnPlugin` for
      the read-write variant of this seam").
- [ ] Confirm with the person who wrote the "do not generalize" comment (git blame /
      commit history) *why* — capture that rationale in the docstring rather than just
      the warning.
- [ ] Consider (docs-only decision, not necessarily a rename) whether `TurnInspecting`
      would be clearer named something like `TurnObserving` to visually distinguish it
      from `ChatTurnPlugin` — record the decision either way, don't silently rename.

### Acceptance Criteria

- [ ] Both protocols' doc comments explain the seam and point at each other.
- [ ] Rationale for keeping them separate is captured in-repo (docstring or ADR), not
      just implied by a terse comment.
- [ ] No behavior change; `make verify` green.
