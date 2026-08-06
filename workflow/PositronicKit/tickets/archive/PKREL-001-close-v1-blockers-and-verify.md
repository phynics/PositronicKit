# PKREL-001: Close All v1 Release Blockers and Run the Full Verification Matrix

**Priority:** P1
**Type:** Release gate
**Depends on:** PKFAST-005, PKFAST-006, PKINT-001, PKINT-002
**Blocks:** PKREL-002, PKREL-004
**Status:** Done

### Summary

Gate the v1 tag on the four open P1 correctness tickets being closed, then prove the whole
package green across the verification matrix established by PKCI-003. This ticket is the
checklist that says "the code is releasable"; it adds no new functionality itself.

### Blocker Set

| Ticket | Why it blocks v1 |
|--------|------------------|
| PKFAST-005 | Batch UTF-8 pointer lifetime in `MiniLMEmbedder` is undefined behavior (pointers retained past their `withUnsafeBufferPointer` closures). |
| PKFAST-006 | Rust bridge copies inference output across the C ABI without shape validation; panics can cross the FFI boundary. |
| PKINT-001 | Only PKOpenRouterProvider has the snake_case stream-decoding fix; OpenAI/Ollama adapters can silently drop every streamed tool call. |
| PKINT-002 | No tool_call ↔ tool_result pairing invariant before request dispatch; violations surface as opaque provider 400s. |

Explicitly **not** blockers (deferred to post-release backlog): PKINT-003 (guarantee/test
hardening — the underlying bug is fixed), PKINT-007 implementation (decision is pre-release
via PKREL-002; implementation may land after the tag if the decided shape is additive).

### Acceptance Criteria

- [x] PKFAST-005, PKFAST-006, PKINT-001, PKINT-002 all closed with tests.
- [x] `make verify`, `make verify-products`, and `make verify-minilm` pass on macOS.
- [x] Linux minimum (Swift 6.1.3) and current (Swift 6.3.2) jobs pass per PKCI-003.
- [x] Uncommitted ticket-status edits (PKCI-003/PKDOC-004 closures, README count) are committed.
- [ ] All three consumers (Monad `swift build`/`swift test`, Shuttle `swift build`/`swift test`,
      Yakamoz `make build`/`make test`) are green against the release candidate commit on
      remote `main`, per the downstream-sync checklist.

### Completion Note (2026-07-05)

PKREL-001 is closed after the four blocker tickets were resolved and the
PositronicKit-local release gates were verified. In this session, the user
confirmed the local `make verify` and `make verify-products` results on their
side, and the ticket archive now reflects that verification state. Consumer
gates remain part of PKREL-004 and are intentionally not closed here.
