# PKINT-002 — Validate tool_call ↔ tool_result Pairing During History Reconstruction

**Priority:** P1
**Type:** Correctness defect (silent request corruption → provider 400)
**Depends on:** None
**Blocks:** Multi-turn tool conversations across providers
**Status:** Done (2026-07-05)
**Surfaced by:** YAK-26 (Yakamoz)

### Summary

Add an explicit invariant to `ChatEngine`'s history reconstruction: before a request is
issued, every assistant `tool_calls` entry must have a matching tool-result message (and vice
versa). A violation must raise a typed `ChatEngineError`, not be shipped to the provider as a
malformed request that 400s with a provider-specific string.

### Current Problem

YAK-26's root cause — `ToolCall.id` coerced `UUID(uuidString:) ?? UUID()`, regenerating a
random id on every reload — is fixed: `ToolCall.id` is now `String`
(`Sources/PKShared/SharedTypes/ToolCall.swift:9`) and reconstruction at
`Sources/PositronicKit/Services/Chat/ChatEngine.swift:415` preserves the provider id.

But the engine still has **no guard** that the reconstructed message array is internally
consistent. Any future bug in persistence, envelope round-trip, or a new provider's id
handling re-produces the same orphaned-`tool_call` shape, and the only signal is the
provider's HTTP 400 (`"No tool output found for function call <id>"`) — opaque, provider-
specific, and surfaced to the end user instead of caught in the runtime.

### Files

- Modify: `Sources/PositronicKit/Services/Chat/ChatEngine.swift` (around `makeHistoryMessage`,
  line ~396, and wherever the per-turn message array is finalized before the LLM call).
- Modify: `Sources/PositronicKit/Services/Chat/...` `ChatEngineError` definition (add a case).
- Modify: the corresponding `ChatEngine`/history reconstruction test file.

### Implementation Requirements

1. After reconstructing the message array for a turn and before issuing the LLM request,
   verify the pairing invariant: the set of assistant `tool_calls` ids equals the set of
   `tool_call_id`s on following tool-result messages (scoped to the same assistant turn).
2. On violation, throw a typed `ChatEngineError.danglingToolCall(id:)` (or
   `.inconsistentToolHistory`) whose `userFriendlyMessage` explains the conversation has an
   unmatched tool call — do **not** issue the request.
3. Keep the check O(n) over the turn's messages; do not re-fetch from persistence.
4. The check must be provider-agnostic (it runs in core, before adapter serialization), so it
   protects every provider uniformly.
5. Do not silently "repair" by dropping the orphaned tool_call — that hides a real persistence
   bug. Fail loudly; repair is a separate, explicit decision.

### Required Tests

- Reconstruct a history containing an assistant `tool_calls` entry with **no** matching
  tool-result and assert the run fails with the typed error before any provider call.
- Reconstruct a well-formed tool history (assistant tool_call + matching tool result) twice
  (simulating reload) and assert it passes the invariant both times and the ids are stable and
  equal to the original provider id (the YAK-26 acceptance test, now asserting the *guard*
  rather than only the decoder).
- A mock-provider test asserting the engine never reaches the provider when the invariant fails.

### Acceptance Criteria

- [ ] A reconstructed history with an unmatched tool_call fails with a typed `ChatEngineError`
      before any network call.
- [ ] A well-formed tool history passes the invariant across repeated reloads with stable ids.
- [ ] The error's `userFriendlyMessage` is actionable and provider-neutral.
- [ ] `make verify` green; Monad/Shuttle build; Yakamoz `make verify` green.

### Verification

```bash
swift test --filter ChatEngine
make verify
```

### Handoff Notes

This is defense-in-depth on top of the `ToolCall.id` fix, not a replacement for it. The value
is converting a provider-specific 400 that reaches the user into a typed runtime error caught
in CI by the round-trip test.

### Resolution

Done on `f04c2f8`. `ChatEngine` now rejects dangling assistant tool calls and dangling tool
results before any provider request, and the regression coverage proves both the failure mode
and the stable provider-id reload path.

Verification on 2026-07-05:

- `swift test --filter ChatEngineTests` passed.
- `make verify` in `PositronicKit` passed.
- Downstream consumer verification is currently blocked by unrelated compile drift:
  Monad and Shuttle still call `ChatRunRequest`, and Yakamoz currently fails on missing
  `TurnIdentity` / inspection-model symbols.
