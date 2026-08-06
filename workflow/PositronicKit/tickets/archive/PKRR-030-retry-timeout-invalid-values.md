---
Priority: P3
Type: Retry / configuration validation
Depends: —
Blocks: PKRR-004
Triage: needs-triage
Status: Done
Confidence: Confirmed
Owner: PKUtilities
Effort: S
Tranche: D (observability, API hygiene, build confidence)
Review: PKR-030
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `9e20e79` (merge `8bf1975`). Added
`RetryConfiguration` (maxRetries ≤ 10, finite/non-negative delays, maxRetryAfter cap,
total-elapsed budget, injectable `JitterStrategy`) and `Timeout` (finite, non-negative,
overflow-safe nanoseconds). `RetryPolicy` validates via `RetryConfiguration`.
`ProviderHTTPFailure` rejects non-finite `Retry-After`. `ToolTimeoutEnforcer` uses `Timeout`.
48 new tests. Additive/backward-compatible. 1576 tests in 235 suites pass on merged main.
---

# PKRR-030 — Retry and timeout knobs accept invalid or unbounded values

## Summary
Public retry accepts arbitrary `maxRetries` and `baseDelay` and converts computed
delay to `UInt64`. Provider `Retry-After` is accepted without a maximum cap. Tool
timeout converts arbitrary `TimeInterval` to nanoseconds. Negative, NaN, infinite, or
extreme values can create immediate loops, excessive sleeps, conversion traps, or
hostile server-controlled delays.

## Current problem
- `Sources/PKUtilities/RetryPolicy.swift:18-55` — public retry accepts arbitrary
  `maxRetries` and `baseDelay` and converts computed delay to `UInt64`.
- `Sources/PKUtilities/ProviderHTTPFailure.swift:23-40` — provider `Retry-After` is
  accepted without a maximum cap.
- `Sources/PositronicKit/Services/Tools/ToolTimeoutEnforcer.swift:38-45` — tool
  timeout converts arbitrary `TimeInterval` to nanoseconds.

## Impact
Negative, NaN, infinite, or extreme values can create immediate loops, excessive
sleeps, conversion traps, or hostile server-controlled delays.

## Recommended change
Introduce validated value types (`RetryConfiguration`, `Timeout`) with finite ranges,
maximum retry-after, attempt/elapsed budgets, and deterministic jitter injection for
tests.

## Acceptance criteria
- [x] Invalid numeric values fail construction with typed errors.
- [x] Server retry hints are capped by host policy.
- [x] Retry has both attempt and total-elapsed limits.
- [x] Regression tests reproduce the current accept-anything behavior before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PKUtilities + PositronicKit tool targets); add a retry/timeout
validation suite. Feeds PKRR-004's "finite, non-negative, overflow-safe timeout"
acceptance criterion.
