# PKFIX-001 — `LLMServiceTests` structured-output assertions fail: utility generations no longer emit a native `.jsonSchema` response format

**Priority:** P2
**Type:** Bug (regression or stale-test contract mismatch — needs decision)
**Depends on:** —
**Blocks:** clean `make verify` on PositronicKit `main`
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, commit `e5147e4`)

### Summary

Two tests in `Tests/PositronicKitTests/LLMServiceTests.swift` fail deterministically on
PositronicKit `main` (confirmed reproducing at base commit `a41c444` and still failing after the
2026-07-10 cleanup batch — they are **pre-existing and unrelated** to PKAPI-015 / PKCLEAN-014 /
the ObservableConversation flake fix):

- `Test "Test generateTitle method"` (`titleGeneration`, `LLMServiceTests.swift:295`) — fails at
  the guard `LLMServiceTests.swift:309-310`: *"Expected generateTitle to use a JSON schema response
  format."*
- `Test "Utility generations use schema-backed structured output"`
  (`utilityGenerationsUseSchemaBackedStructuredOutput`, `LLMServiceTests.swift:325`) — fails at
  `LLMServiceTests.swift:334-335`: *"Expected generateTags to use a JSON schema response format."*
  (The same suite also asserts the same shape for `generateTitle` at `:348-349` and
  `evaluateRecallPerformance` at `:378-379`.)

Both assert `guard case let .jsonSchema(schema) = mockClient.lastResponseFormat` and then check
`schema.name == "llm_title"` / `"llm_tags"`. The call *does* reach the mock (the value assertions
just above — e.g. `title == "SwiftUI Basics"` at `:308`, `tags == ["swift", "tests"]` at `:332` —
pass), but `lastResponseFormat` is **not** `.jsonSchema`.

### Root cause (traced)

Utility generation routes:
`LLMService+Utilities.swift` (`generateTitle`/`generateTags`/`evaluateRecallPerformance`, each
passing `structuredOutput: .jsonSchema(StructuredOutputSchema(...))` at `:114`, `:137`, `:186`)
→ `runUtilityGeneration` → `sendStructured` → `sendStructuredMessage`
(`LLMServiceProtocol+StructuredOutput.swift:5`) → `chatStream(structuredOutput:)`
(`LLMServiceProtocol+StructuredOutput.swift:27`) → `StructuredOutputExecution.prepareRequest(...)`
(`LLMServiceProtocol+StructuredOutput.swift:36,81`) → the request's `responseFormat` comes from the
**provider's registered `StructuredOutputAdapter`** and is passed on to the stream client at
`LLMServiceProtocol+StructuredOutput.swift:47` / `LLMService+Stream.swift:94`, where the mock records
it as `lastResponseFormat`.

The `responseFormat` value is therefore whatever the *applicable adapter* produces:

- **Default/fallback adapter** (`PKShared/SharedTypes/StructuredOutputAdapter.swift:83`) emits
  `responseFormat: .jsonObject` — never `.jsonSchema`.
- **`OpenAICompatibleStructuredOutputAdapter`** (`PKOpenAIProvider/OpenAICompatibleStructuredOutputAdapter.swift:28-39`)
  deliberately implements `.jsonSchema` via a **synthetic forced tool**
  (`responseFormat: nil`, `toolChoice: .function("emit_structured_response")`,
  `syntheticToolName:`) — also never `.jsonSchema`.

Adapters are looked up by configured provider from `StructuredOutputAdapterRegistry`, and provider
modules register their adapter in their own `register()` entry point
(`StructuredOutputAdapter.swift:58-73`). **The `PositronicKitTests` target does not import or call
any provider module's `register()`** (grep of `LLMServiceTests.swift` + `Tests/PKTestSupport/*.swift`
for `register`/`PKOpenAIProvider` is empty), and the test's `LLMService` is built with
`MockConfigurationService()` defaulting to `.openAI`. So with no OpenAI adapter registered, the
registry falls back to the default adapter → `responseFormat == .jsonObject` → the
`guard case .jsonSchema` fails.

This lines up with the recent provider split (`51e5a9c refactor: split concrete LLM providers into
separate targets`) and the structured-output strategy work (SDC series / `PKAPI-007`): the tests were
written against an older contract where the utility path produced a native
`.jsonSchema(name:)` response format, but no adapter reachable from the test target produces that
shape today.

### The decision this needs (why needs-info)

Determine which contract is correct, then make code and tests agree:

- **(a) Native-schema is intended for OpenAI:** there should be a native OpenAI adapter that emits
  `responseFormat: .jsonSchema(StructuredOutputSchema(name: "llm_title"/"llm_tags", ...))`, and it
  must be **registered and reachable from the test** (e.g. register it in the test setup, or have the
  core register a default native-schema adapter for `.openAI`). Fix = restore/register that adapter so
  utility generations emit the named JSON-schema response format the tests assert.
- **(b) Synthetic-tool / `.jsonObject` is the intended cross-provider strategy** (as
  `OpenAICompatibleStructuredOutputAdapter` and its doc comment state): then the assertions are stale.
  Update the two tests to assert on the *actual* structured-output shape — the prepared synthetic tool
  (`toolChoice`/tool schema/`syntheticToolName`) or `.jsonObject` — rather than
  `mockClient.lastResponseFormat == .jsonSchema`, while still verifying the schema content
  (`"tags"`/`"title"`) round-trips.

Cross-check the related pre-existing assertions in the same suite before deciding: `evaluateRecallPerformance`
(`:378-379`) and the second `generateTitle` inside `utilityGenerationsUseSchemaBackedStructuredOutput`
(`:348-349`) assert the same `.jsonSchema` shape and will need the same treatment.

### Implementation Requirements

- [ ] Decide (a) vs (b) above — this is the needs-info blocker; confirm with the current
      structured-output strategy owner (SDC / PKAPI-007 context) whether utility generations are meant
      to use native JSON-schema response format or the synthetic-tool mechanism.
- [ ] Make implementation and tests agree per the chosen path:
  - (a) register a native-schema adapter for `.openAI` reachable from `PositronicKitTests`, or
  - (b) rewrite the four assertions (`:309`, `:334`, `:348`, `:378`) to match the synthetic-tool /
    `.jsonObject` shape.
- [ ] Confirm no other suite depends on the old contract: grep tests for
      `lastResponseFormat`, `.jsonSchema(`, `emit_structured_response`, and adapter registration.
- [ ] Verify downstream real behavior is unaffected (Monad/Yakamoz utility title/tag generation) —
      this is only about which structured-output wire strategy is used, not whether structured JSON is
      produced.

### Acceptance Criteria

- [ ] `LLMServiceTests` `titleGeneration` and `utilityGenerationsUseSchemaBackedStructuredOutput`
      pass, asserting the *actual, intended* structured-output contract.
- [ ] `make verify` green on PositronicKit `main` (these are currently the 2 outstanding failures).
- [ ] If the public/structured-output contract changed, CHANGELOG updated.

### Reproduction

```
cd PositronicKit && swift test --filter LLMServiceTests
# → "Test run with N tests ... failed ... with 2 issues"
#   generateTitle @ LLMServiceTests.swift:309-310
#   generateTags  @ LLMServiceTests.swift:334-335
```
