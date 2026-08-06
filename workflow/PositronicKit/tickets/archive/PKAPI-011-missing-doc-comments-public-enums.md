# PKAPI-011 — Missing/thin documentation comments on public types

**Priority:** P3
**Type:** Documentation
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-10, commit `9cea1bf`, merged into `main`) — documented the six originally
flagged types plus the full extended inventory: PKShared/SharedTypes (the `LLMProviderContracts.swift`
cluster, `Message` nested types, structured-output/serialization/workspace types), PKPrompt's
compression pipeline and core DSL primitives (`SystemPrompt`/`UserPrompt`/`TextPrompt`/
`HistoryPrompt`/`EmptyPrompt`), and PKTestSupport's mock types (documenting configurable behavior +
call-capture state). `HealthStatus` still existed (not deleted by PKCLEAN-008) and was documented.
Docs-only, no behavior/API change. One `make verify` `validate-docs` failure surfaced during
review — two doc comments used docc double-backtick cross-references (`` ``StableHash`` ``,
`` ``StructuredCompressionPlanner/plan`` ``) that docc couldn't resolve (cross-module symbol,
parameterized method); downgraded to plain code-span text in a follow-up commit (`1d5d5d0`).
`swift test` green (940 tests / 160 suites, up from PKAPI-013 landing first in the merge order).

### Summary

Confirmed. Several public enums/structs have no or minimal doc comments, against the
"every public declaration should have a documentation comment" convention:

- `GenerationParameters` (`Sources/PKShared/SharedTypes/GenerationParameters.swift:4`) —
  one-line "Parameters for LLM generation," no per-field docs for `temperature`,
  `maxTokens`, `topP`, `frequencyPenalty`, `presencePenalty`, `seed`.
- `LLMProvider` (`Sources/PKShared/SharedTypes/LLMProvider.swift:3`) — no doc comment at
  all on the enum or its cases.
- `ToolProvenance` (`Sources/PKShared/Tools/Tool.swift:3` area) — no doc comment.
- `MemorySavePolicy` (`Sources/PKShared/SharedTypes/PersistenceTypes.swift:4`) — no doc
  comment (also see PKAPI-010 for its case-naming issue — fix both in the same pass).
- `CachePolicy`, `CompressionStrategy`, `PromptSectionType`, `PromptSectionRole`,
  `PromptPriority` (all in `Sources/PKPrompt/PromptBuilder/Builder/Node/PromptLeaf.swift`,
  not `PromptPrimitive.swift` as originally reported — the review's file name was
  slightly off but the finding is correct) — none of these five types have any doc
  comment.

### Extended inventory (2026-07-09 codebase-wide sweep)

A follow-up sweep by discovery agents (verified spot-checks) found the gap is much wider
than the original six types. Additional undocumented public types, by target:

**PKShared / SharedTypes** (concentrated in `LLMProviderContracts.swift`):
`LLMToolDefinition`, `LLMMessage`, `LLMClientProtocol`, `LLMToolChoice`,
`LLMResponseFormat`, `LLMResponseSchema`, `LLMStreamChoice`, `LLMStreamChunk`,
`LLMTokenUsage`, `LLMTokenUsagePromptDetails`, `LLMToolCallDeltaFunction`,
`EndpointComponents`, `ExternalLLMProviderRegistry`; plus `Message.MessageRole`,
`Message.ContextGatheringProgress` (`Message.swift:52,89`), `ToolOutputSubmission`,
`StructuredOutputSchema`, `StructuredOutputDecoder`, `StructuredOutputDecodingError`,
`LLMToolCallRecoveryState`, `SerializationUtils`, `HealthStatus`¹,
`WorkspaceTrustLevel`, `WorkspaceReference.WorkspaceLocation`,
`WorkspaceReference.WorkspaceStatus`, `StructuredCompressionNodeMetric`,
`StructuredCompressionMetrics`, `PKErrorDomain`, `StableHash`.

**PKPrompt**: `TokenBudget`, `StructuredCompressionPlanner`, `CompressionReason`,
`CompressionAction`, `StructuredCompressionNode`, `PlannedNodeAction`,
`StructuredCompressionPlan`, `StructuredNodeMetadata`, `StructuredDiffHint`,
`SummaryRequest`, and — notably — the core DSL primitives `SystemPrompt`, `UserPrompt`,
`TextPrompt`, `HistoryPrompt`, `EmptyPrompt`, which are the very first types a new
consumer touches.

**PKTestSupport** (shipped library product — its API is user-facing): `MockLLMClient`,
`MockLLMService`, `MockAgentTemplateStore`, `MockConfigurationService`,
`MockEmbeddingService`, `MockMemoryStore`, `MockMessageStore`, `MockPersistenceService`,
`MockTimelinePersistence`, `MockToolPersistence`, `MockWorkspacePersistence`,
`StructuredOutputFixtures`. For the mocks, the doc comment should state what behavior is
configurable and what call-capture state is exposed for assertions.

¹ `HealthStatus` may be deleted along with `HealthCheckable` (PKCLEAN-008) — skip
documenting anything scheduled for removal; check PKCLEAN-007/008/010 before writing docs
for types those tickets delete.

### Implementation Requirements

- [ ] Add a doc comment to each type above explaining its purpose and, where non-obvious
      (e.g. `CachePolicy.stable`/`.semiStable`/`.volatile`, `PromptPriority`'s numeric
      values), a one-line comment per case.
- [ ] For `GenerationParameters`, document what happens when a field is `nil` (provider
      default? omitted from the request entirely?) since that's the actual non-obvious
      behavior a reader needs.
- [ ] Skip re-litigating naming here (that's PKAPI-010 for `MemorySavePolicy`) — this
      ticket is purely additive documentation, no renames.

### Acceptance Criteria

- [ ] All six types listed have doc comments; non-obvious cases/fields documented.
- [ ] No behavior change; `make verify` green.
