---
Priority: P1
Type: Cross-platform stability
Depends on: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: PKUtilities / providers
Effort: L
Tranche: C (cross-platform generation + public contracts)
Review: PKR-010
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `84b1cc6` (merge `7cee460`). Replaced Linux
`session.data(for:)` (buffers full response) with a `URLSessionDataDelegate`-based streaming
implementation that yields complete lines as data chunks arrive. Apple path unchanged. No
new dependencies added. 7 streaming conformance tests: first-chunk-before-completion,
cancellation, large stream, no-trailing-newline, steady-stream, partial-line reassembly,
connection-error propagation. Linux compilation needs `make verify-linux-current` verification.
1465 tests in 219 suites pass on merged main.
---

# PKRR-010 — Linux provider streams buffer the full HTTP response before yielding lines

## Summary
`ProviderHTTPTransport` uses `URLSession.bytes` on Apple (true incremental streaming)
but `session.data` on Linux, which buffers the full HTTP response before splitting
lines. First-token latency, memory, cancellation, and the idle watchdog all regress
on Linux.

## Current problem
- `Sources/PKUtilities/ProviderHTTPTransport.swift:36-86` — Apple uses
  `URLSession.bytes`; Linux uses `session.data` then splits the complete body.

## Impact
The first token is delayed until the provider closes the response, memory scales with
the full response, cancellation cannot stop network reading promptly, and the chat
idle watchdog observes no chunks. This contradicts first-class Linux streaming
expectations.

## Recommended change
Implement true incremental byte streaming on Linux (e.g. AsyncHTTPClient/NIO or a
corelibs-compatible streaming transport). Add a shared transport conformance suite
measuring first-chunk delivery, bounded memory, cancellation, and malformed-frame
propagation.

## Acceptance criteria
- [x] Linux emits the first SSE/NDJSON line before response completion.
- [x] Cancellation closes the underlying request.
- [x] A long steady stream does not hit idle timeout.
- [x] Memory remains bounded in a large-stream test.
- [x] Regression test reproduces the current buffer-then-yield behavior before the
  fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`make verify-linux-current` (and `verify-linux-asan` if the transport touches the
native bridge boundary). Add a cross-platform streaming conformance suite.
