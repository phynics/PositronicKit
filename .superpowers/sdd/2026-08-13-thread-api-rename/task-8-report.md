# Task 8 verification report

Date: 2026-08-13
Branch: `codex/thread-api-rename`
Scope: native macOS verification and cleanup of first-party production calls that still selected deprecated Timeline APIs.

## Outcome

Task 8 is complete. The remaining production call sites identified by the release warning audit now use canonical Thread initializers and properties. Compatibility declarations, historical decoding, and stable identifiers were preserved.

The branch is buildable and the relevant migrated-call-site tests pass. The prescribed `make verify` gate remains non-zero for a pre-existing Xcode 27 beta DocC product-layout mismatch. The full test run also retains four pre-existing/environmental failures documented below; no branch-caused failure remains.

## Branch changes

Updated only internal production calls in:

- `ChatEngine+TurnPreparation.swift`
- `ChatTurnFollowUpPolicy.swift`
- `ExternalToolOutputSubmissionGate.swift`
- `LLMStreamingStage.swift`
- `MessagePersistenceStage.swift`
- `ToolCallExtractionStage.swift`
- `MessageStoreProtocol.swift`
- `InMemoryMessageStore.swift`
- `TimelineManager.swift`
- `ToolRouter.swift`

The changes replace deprecated `ConversationMessage`, `CompletedTurn`, `TurnSnapshot`, and `PromptBuildContext` argument labels, and replace deprecated `timelineId`/`timelineID` property reads with canonical `threadID` access. The structured logging key `LogKeys.timelineID` was intentionally retained because it is a stable diagnostic identifier. Historical `runtimeTimeline` decoding and comparisons were intentionally retained so persisted legacy workspace values continue to work. Compatibility adapters, protocols, and dual conformances were not modified.

## Verification evidence

- `git diff --check HEAD~7..HEAD`: passed.
- Public API audit with the Task 8 `rg` expression: only the expected compatibility/historical matches remain (`timelineManager` compatibility property, `TimelinePersistenceProtocol`, `LegacyTimelinePersistenceAdapter`, `InMemoryThreadPersistence` dual conformance, and `TimelineAgentInstanceManagerProtocol`).
- `make verify`: build and all 29/29 documentation story tests passed; the gate then stopped at `validate-docs` with the missing path `.build/arm64-apple-macosx/debug/Modules`.
- Remaining gate targets run independently: `verify-doc-snippets` passed with 33 blocks; `audit-default-linkage` passed; `verify-products`, `verify-examples`, and `verify-pktestsupport` passed.
- `swift build -c release` after the patch: passed (`Build complete!`). The deprecation audit contains only the intentional compatibility adapters/protocols and the two historical `runtimeTimeline` comparisons in `TimelineManager+Attachments.swift` and `TimelineManager+Lifecycle.swift`; no patched first-party call site warns.
- Focused migrated-call-site tests passed: `swift test --filter 'CoreAPIClarityTests|ThreadIdentifierCompatibilityTests|WorkspaceReferenceTests|ConversationMessageTests|InMemoryStoresContractTests|PersistenceProtocolTests|ToolRouterTests'` — 100 tests in 16 PositronicKit suites plus 16 tests in 3 PKShared suites.
- A combined focused run including `FacadeOneShotTests` and `HydrationFailurePropagationTests` reproduced only their two known provider-error identity assertions; all other selected suites passed.
- Full `swift test`: 990 tests in 147 suites, with the four issues classified below.

## Classified failures

### Environment/toolchain failures

1. The first sandboxed `make verify` attempt could not open `/Users/atakan/.cache/clang/ModuleCache`. Rerunning the same command with the required host compiler-cache permission proceeded normally. This is an execution-environment restriction, not a source failure.
2. `Scripts/validate-docc.sh` expects `.build/arm64-apple-macosx/debug/Modules`, while Xcode 27 beta emits the build products under its newer `arm64e`/`.build/out` layout. This is the documented baseline failure and was not changed in Task 8.
3. `PKUtilitiesTests/ProviderHTTPTransportTests.swift:238` expected `CancellationError` but received `NSURLErrorDomain` `-999` (`cancelled`) while waiting for response headers. This is Foundation/URLSession cancellation representation on the current toolchain; it is outside the renamed API call sites.
4. `PKPromptTests/Pipeline/PromptJournalProcessTests.swift:7` could not locate the built `PKPromptJournalProcessFixture` executable. This matches the current SwiftPM/Xcode product-layout environment and is unrelated to the branch changes.

### Pre-existing source behavior

`FacadeOneShotTests.swift:197` and `HydrationFailurePropagationTests.swift:85` fail their identity checks because the wrapped `NSError` is value-equivalent but not object-identical to the original foreign error. The affected assertions and `LLMStreamError` implementation were unchanged by this branch; the failures also reproduce in the focused run after the canonical-call cleanup. They are therefore not Task 8 regressions.

## Final classification

No branch-caused verification failure remains. The release build and focused canonical/compatibility tests pass. The outstanding non-zero gate results are the documented DocC layout, Foundation cancellation, fixture lookup, and pre-existing error-identity issues.
