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
