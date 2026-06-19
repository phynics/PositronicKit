# PositronicKit Ticket Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved PositronicKit ticket batch with test-first changes, per-ticket verification, and per-ticket commits.

**Architecture:** Provider-facing tickets share a new HTTP transport and error-classification layer in shared/core modules so adapters can reuse consistent retry behavior and deterministic tests. Runtime, documentation, API policy, and Linux validation changes stay isolated to their owning modules and CI entry points.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest/Swift Testing, DocC, GitHub Actions

## Global Constraints

- Keep public provider initialization source-compatible.
- Keep diagnostics user-friendly and never expose credentials.
- Run tests without external network access.
- Preserve cancellation semantics and existing defaults unless a ticket changes configurability.
- Verify, commit, and push after each ticket.

---

### Task Sequence

- [ ] Ticket 1: Add failing tests for HTTP status classification, retry exhaustion, `Retry-After`, and cancellation; implement shared HTTP-aware provider errors and retry policy updates; run focused tests; commit and push.
- [ ] Ticket 2: Add failing tests for every `UnconfiguredLLMService` throwing and streaming entry point; replace crashing/hanging behavior with `.notConfigured`; run focused tests; commit and push.
- [ ] Ticket 3: Add failing transport-injection and provider contract tests; implement injectable transport abstraction and provider-specific adapters; run focused provider tests; commit and push.
- [ ] Ticket 4: Add documentation validation in CI and compile-backed examples; update README, DocC, setup, architecture, and usage docs; run docs/example validation; commit and push.
- [ ] Ticket 5: Define versioning policy, generate/record public API baseline, and add CI API break detection; run the new validation flow; commit and push.
- [ ] Ticket 6: Add Linux manifest/CI support for transport-neutral modules and document product support; run macOS verification locally and leave Linux to CI where necessary; commit and push.
- [ ] Ticket 7: Add failing tests for default, selective, and deny-all runtime tool policies; implement `RuntimeToolPolicy`; run timeline/tool tests; commit and push.
- [ ] Ticket 8: Add failing tests for configured, partial, and absent OpenRouter attribution headers via injectable transport; implement optional attribution config; run focused tests; commit and push.
