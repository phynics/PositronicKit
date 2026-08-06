# PKAPI-003 — Unify `think`/`thinking`/`reasoning` terminology across message/event types

**Priority:** P3
**Type:** API design / naming
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, commit `a2a8ad0`, merged into `main`) — `Message.think` →
`.reasoning`, `LLMStreamDelta.thinking` → `.reasoning`, `ChatEvent.DeltaEvent.thinking`/
`.thinking(_:)` → `.reasoning`/`.reasoning(_:)`. `LLMMessage.reasoning` already had the right name.
Provider wire-format field names (Ollama's `thinking` JSON key, OpenRouter/OpenAI's `reasoning` JSON
key, Anthropic's `thinking_delta` event) are untouched — only the shared vocabulary changed. Fixed
during review: two call sites the original diff got backwards (`AnthropicClient`'s wire-format
decode should've stayed `.thinking`; its `markYieldedIfNeeded` check on the shared `LLMStreamDelta`
needed `.reasoning`). Downstream grep found real usage in Monad (`ChatREPL+Streaming.swift`) and
heavy usage in Yakamoz (`ChatView`, `MessageBubble`, `ResponseInspectorView`,
`ToolTranscriptPresentation`, `TranscriptRowPresentation`, `ChatEventReducer`, `YakamozRuntime`,
`InspectionDTOs`) — migration deferred to their next PositronicKit pin bump (consistent with
PKAPI-001/004/007's precedent; no dedicated follow-up ticket filed). `swift test` green (932 tests
/ 159 suites). CHANGELOG updated (Breaking).

### Summary

Confirmed: the same concept (a reasoning-model's chain-of-thought content) has three
different field names across four public types:

- `Message.think: String?` (`Sources/PKShared/SharedTypes/Message.swift:23`)
- `LLMMessage.reasoning` (`Sources/PKShared/SharedTypes/LLMProviderContracts.swift:99-107`)
- `LLMStreamDelta.thinking: String?` (`LLMProviderContracts.swift:191-197`)
- `ChatEvent.DeltaEvent.thinking` (`Sources/PKShared/SharedTypes/ChatEvent.swift`, via the
  `.thinking(_:)` factory shortcut)

The code already documents the provider fragmentation causing this
(`LLMProviderContracts.swift:103-106`: "Ollama → `thinking`, OpenRouter → `reasoning`")
— that's a legitimate reason for *provider adapters* to speak each provider's wire
vocabulary, but PositronicKit's own public types shouldn't inherit three different names
for the same concept.

### Implementation Requirements

- [ ] Pick one provider-neutral term for the public-facing types — `reasoning` is already
      used on `LLMMessage` (the more "official" contract type) and is the more common
      industry term (OpenAI/Anthropic reasoning APIs) — and rename `Message.think` →
      `Message.reasoning`, `LLMStreamDelta.thinking` → `LLMStreamDelta.reasoning`,
      `ChatEvent.DeltaEvent.thinking`/`.thinking(_:)` → `.reasoning`/`.reasoning(_:)`.
- [ ] Leave provider-adapter-internal code (the bits that literally construct Ollama's
      `thinking` JSON field or OpenRouter's `reasoning` field) alone — this is about the
      shared vocabulary, not the wire format.
- [ ] Grep all three consumers (Monad/Shuttle/Yakamoz) for `.thinking`/`.think` usage —
      Yakamoz's inspector drawer almost certainly renders this field, per
      `workflow/Yakamoz/` UI work.

### Acceptance Criteria

- [ ] One term (`reasoning`) used consistently across `Message`, `LLMStreamDelta`,
      `ChatEvent.DeltaEvent`/factory shortcuts.
- [ ] Downstream consumers updated and compiling.
- [ ] `make verify` green; CHANGELOG updated (breaking rename).
