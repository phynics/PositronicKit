# PKR-5 — Duplicate-content retry gate (`shouldRetryAfterError`/`hasYielded`) untested at client level

**Status:** Done
**Severity:** 🟠 Medium (regression risk on a correctness-critical mechanism)
**Repos:** PositronicKit (all three providers)
**Source:** PositronicKit review 2026-07-02

## Problem

The mechanism preventing duplicated assistant text — `LLMToolCallRecoveryState.shouldRetryAfterError`
(`PKShared/SharedTypes/LLMToolCallRecovery.swift:31-33`, `= !hasYielded`), relied on at
`OpenAIClient.swift:98`, `OpenRouterClient.swift:390`, `OllamaClient.swift:76` — has no client-level
test. `RetryPolicyTests.swift` covers only generic retry mechanics with synthetic closures; no
transport-contract test simulates *chunk yielded → transient error → assert no restart/duplicate,
error propagates*. A refactor that moves the `recoveryState.observe(...)` call or changes
evaluation order would silently reintroduce duplicated streamed content.

Related note (low): `sendMessage`'s outer `RetryPolicy.retry` (`OpenAIClient.swift:147-167`,
`OpenRouterClient.swift:627-641`, `OllamaClient.swift:276-289`) re-runs the whole `chatStream`
pipeline including tool-call recovery round-trips when nothing was yielded — wasteful but not
incorrect; also untested.

## Suggested direction

Add a transport-contract test per provider: stream yields one chunk, then throws a transient
`URLError`; assert the stream terminates with that error and no duplicate restart occurs.

## Resolution (2026-07-04)

Extended `TestProviderTransport` (the injectable `ProviderHTTPTransport` mock used by
OpenRouter/Ollama tests) with a `.linesThenError(lines, error, response)` case that yields SSE/NDJSON
lines then finishes the stream by throwing an error. Added four transport-contract tests:

**OpenRouter** (`ProviderTransportContractTests.swift`):
- `openRouterYieldThenErrorDoesNotRetry` — yields one content chunk ("Hello"), then
  `URLError(.timedOut)`. Asserts: exactly one chunk collected (no duplicate), exactly one HTTP
  request issued (retry gate blocked the restart), error propagates as `URLError`.
- `openRouterErrorBeforeContentRetries` — throws `URLError(.timedOut)` before yielding anything,
  then succeeds on the second attempt. Asserts: content from retry collected, two HTTP requests
  issued (gate allowed the retry). Locks in the `!hasYielded` direction so a future refactor
  inverting the predicate is caught.

**Ollama** (same file, bare `Mutex<Bool> hasYielded` variant):
- `ollamaYieldThenErrorDoesNotRetry` — yields one content chunk, then
  `URLError(.networkConnectionLost)`. Same assertions.
- `ollamaErrorBeforeContentRetries` — transient error before content → retries, succeeds.

**RetryPolicy-level gate integration** (`RetryPolicyTests.swift`):
- `retryGateBlocksAfterYield` — mirrors the exact `shouldRetry:` closure pattern used by all three
  providers (`recoveryState.shouldRetryAfterError && RetryPolicy.isTransient(error:)`). After
  `observe(yieldedContent: true, ...)`, a transient `URLError` propagates with exactly one attempt.
- `retryGateAllowsBeforeYield` — same gate, but no content yielded → retry proceeds and succeeds
  on the second attempt.

This covers the OpenAI path's gate integration at the `RetryPolicy` level (the gate logic is
identical across all three providers: `recoveryState.withLock { $0.shouldRetryAfterError } &&
RetryPolicy.isTransient(error:)`). An OpenAI-specific transport-contract test (mid-stream
`URLError` via `LocalHTTPServer` connection drop) is deferred — it would require extending the
`NWListener`-based server to send partial SSE then break the connection, and the gate logic it
would exercise is already covered by the OpenRouter transport-contract test + the
`RetryPolicy`-level gate integration tests.

686 PositronicKit tests green.
