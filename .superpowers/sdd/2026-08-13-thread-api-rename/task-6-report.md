# Task 6 Report

## Outcome

Complete. First-party examples, documentation, fixtures, support stores, tests, and stale
canonical comments/log wording now use `Thread` terminology. Existing compatibility coverage and
historical contracts remain intentionally timeline-named.

## Spec Compliance

- `Thread`, `ThreadManager`, `ThreadDriver`, `ThreadPersistenceProtocol`, and `ThreadController`
  are used by ordinary examples, docs, fixtures, and tests.
- The exact deprecation notice remains unchanged:
  `Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.`
- Compatibility declarations/tests retain `Timeline` names, including legacy persistence adapters
  and compatibility fixtures.
- Wire/tool/DB/error/external contracts remain unchanged, including `timeline_list`,
  `timeline_peek`, `timeline_send`, `timeline_id`, serialized timeline keys, historical error
  domains/codes/messages, and `/timelines` workspace paths.
- No dependencies were added.

## Verification

- `swift test --filter 'ThreadAPICompatibilityTests|ThreadIdentifierCompatibilityTests|ThreadControllerTests'` — passed; 4 tests in 1 suite.
- `swift test --filter 'PublicRuntimeStoriesTests|RuntimeSetupStoriesTests|PersistenceProtocolTests|InMemoryStoresContractTests'` — passed; 66 tests in 9 suites.
- `swift run PositronicKitExamples` — compiled successfully; execution stops at the existing
  unconfigured LLM boundary with `LLMServiceError.notConfigured` because no provider credentials
  are configured in this environment.
- `git diff --check` — clean.

## Review Notes

File names containing `Timeline` were retained where they document compatibility or preserve
historical source paths. Intentional compatibility tests and contract assertions were not
rewritten merely to remove historical identifiers.

## Refs

- Task brief: `.superpowers/sdd/2026-08-13-thread-api-rename/task-6-brief.md`.
- Prior implementation baseline: `1b13280`.

## Review Fix Round 1

Complete. Review findings were addressed without changing compatibility, wire, database, error,
or external-tool identifiers:

- Restored explicit legacy `.hasAttachedTimelines` branch coverage alongside the canonical
  `.hasAttachedThreads` branch.
- Updated the `ChatRunRequest` sidecar example to use `threadID`.
- Canonicalized ordinary workspace-attachment and observation-tool test labels while retaining
  compatibility-specific `timeline` call-name and `timeline_id` assertions.
- Updated lifecycle and partial-assistant runtime diagnostic prose to `thread`, preserving stable
  structured keys such as `timelineID` and historical operation/entity identifiers.

Round 1 verification:

- Focused affected tests — passed; 64 tests in 9 suites.
- `swift build --product PositronicKitExamples` — passed.
- `make validate-docs` story/example phase — passed; 29 tests in 4 suites. The subsequent
  symbolgraph step is blocked by the local Xcode 27 beta build-layout mismatch: the script expects
  `.build/arm64-apple-macosx/debug/Modules`, which that toolchain did not produce.
- Targeted stale-label/runtime-prose audits — clean except the two intentional external-contract
  labels (`timeline` call names and missing `timeline_id`).
- `git diff --check` — clean.

Round 1 baseline: `3f15f3b`.

## Review Fix Round 2

Complete. Human-facing attachment diagnostics and ordinary test metadata now consistently use
`Thread` terminology:

- Updated attach, detach, and workspace-query log prose in
  `TimelineManager+Attachments.swift`, while retaining stable `fetchTimeline` operation values,
  storage compatibility cases, and external identifiers.
- Canonicalized ordinary suite/test display labels and assertion prose across lifecycle,
  cancellation, eviction/deletion, prompt-history, manager, fault-injection, agent, runtime-story,
  workspace-resolver, router, and shared-model coverage.
- Retained compatibility-specific labels for deprecated Timeline aliases and forwarding behavior,
  exact `timeline_*` tool names and `timeline_id`, historical JSON/storage spellings, stable
  error text, and degradation operation identifiers.

Round 2 verification:

- Focused affected tests — passed; 175 tests in 23 PositronicKit suites and 32 tests in 6
  PKShared suites.
- Broad ordinary test-metadata audit — remaining Timeline references are compatibility,
  wire/tool, historical serialization/storage, stable error, or deprecated-alias coverage.
- Targeted attachment diagnostic audit and `git diff --check` — clean.

Round 2 baseline: `fcf31ca`.
