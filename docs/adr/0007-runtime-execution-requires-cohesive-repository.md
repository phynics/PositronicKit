---
status: accepted
---

# Runtime execution requires a cohesive repository

Every Turn execution path uses one `ThreadRuntimeRepository` for Thread history, admission,
tool intent and results, terminal outcomes, replay, and Request-ID uniqueness. We remove the
package-internal independent Thread/message-store path and its process-local idempotency gate
because a second, non-atomic execution path weakens locality and contradicts the runtime's
single-owner durability model. Standalone managers that cannot execute a Turn may retain optional
repository dependencies.

This decision supersedes ADR 0003's allowance for independent Thread and message stores and the
compatibility-path preservation choice recorded in issue #100. ADR 0003's cohesive ownership
model remains in force. Issue #117 owns the implementation and verification of this decision.

## Amendment: 2026-09-19

Summary projections stay outside the cohesive repository. `Sources/PositronicKit/CONTEXT.md`
defines the Timeline Runtime Repository as the transactional owner of Timeline metadata,
append-only history, Turn admission with its input message, tool intent and results, terminal
outcomes, and stale-Turn recovery; summaries are none of those, and the runtime neither writes nor
reads them. A host summary pipeline stores them through the optional `TimelineSummaryStore`
capability instead. The cohesive repository still owns every record a Turn execution reads or
writes, so this narrows the repository to execution-critical state rather than reopening a second
execution path.
