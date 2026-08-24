---
status: accepted
---

# ThreadRuntimeRepository owns Turn durability

The v4 design assigns one cohesive ThreadRuntimeRepository to own Thread metadata, append-only
messages, Turn records, Request-ID uniqueness, tool intents/results, terminal outcomes, and
stale-Turn recovery through atomic behavioral transitions. We reject coordinating several
low-level stores from the Turn engine because durable-before-side-effect ordering, idempotency,
and terminal truth need one transaction boundary; PromptJournal remains separate cache/emission
state.

Turn admission is specifically a transaction over the new Turn, its active pointer, Request-ID
record, and the optional input `ThreadMessage`. A successful admission makes all of them visible
together; a failed admission exposes none, and retrying an uncertain result with the same Request
ID and caller-intent fingerprint joins or replays the existing Turn without appending the input
again. Prompt assembly treats an input already present in the repository history as the admitted
input rather than appending a second copy. `completeTurn` is the corresponding boundary for a
normal terminal assistant message and its `TurnOutcome`; a terminal message must belong to the
same Thread as its Turn. Independent Thread and message stores remain a legacy, non-atomic path
and are not a v4 crash guarantee.
