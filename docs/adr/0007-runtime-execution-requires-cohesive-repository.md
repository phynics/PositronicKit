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
