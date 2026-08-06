# PKDEEP-006-impl — Merge RenderedPrompt projection + messages into one file

**Priority:** P3
**Type:** Implementation (deepening)
**Depends on:** PKDEEP-006 (research, done)
**Blocks:** none
**Triage:** ready-for-agent
**Status:** Done (2026-07-08, commit `adf1692`)

### Summary

Merge `RenderedPromptProjection.swift` (56 lines), `RenderedPrompt+Messages.swift`
(37 lines), and `Prompt+OpenAI.swift` (100 lines) into one file
(`RenderedPrompt+Messages.swift`), with `RenderedPromptProjection` as a private struct.
`StructuredPromptMetadata` was already folded by PKDEEP-004-impl — not in scope.

### Implementation requirements

1. **Merge `RenderedPromptProjection` into `RenderedPrompt+Messages.swift`** as a
   `private struct` at the top of the file. Its `init(prompt: RenderedPrompt)` body
   stays the same.

2. **Move `buildMessages()` and its private helpers** from `Prompt+OpenAI.swift` into
   `RenderedPrompt+Messages.swift`. This includes:
   - `buildMessages() -> [LLMMessage]`
   - `buildSystemMessage(from:) -> LLMMessage?`
   - `buildHistoryMessages(from:) -> [LLMMessage]`
   - `buildUserQueryMessage(from:) -> LLMMessage?`
   - `convertHistoryMessage(_:) -> LLMMessage`
   - `buildAssistantMessage(_:) -> LLMMessage`
   - `buildToolResponseMessage(_:) -> LLMMessage`

3. **Delete `RenderedPromptProjection.swift`** — content moved into the merged file.

4. **Delete `Prompt+OpenAI.swift`** — content moved into the merged file.

5. **Preserve both public APIs**:
   - `buildConversationMessages() -> [Message]` — stays public, zero production callers
     but tested
   - `buildMessages() -> [LLMMessage]` — stays public, 3 production callers

6. **No test changes needed** — zero tests reference `RenderedPromptProjection` by name.

### Acceptance criteria

- [ ] `RenderedPromptProjection.swift` deleted
- [ ] `Prompt+OpenAI.swift` deleted
- [ ] All content merged into `RenderedPrompt+Messages.swift`
- [ ] `RenderedPromptProjection` is a `private struct` within the merged file
- [ ] `buildConversationMessages()` and `buildMessages()` public APIs unchanged
- [ ] `make verify` green

### Verification

```bash
cd PositronicKit
make verify
```

### Cross-links

- Research: [PKDEEP-006](../PKDEEP-006-prompting-helper-fold.md)
- `StructuredPromptMetadata` already folded by PKDEEP-004-impl
