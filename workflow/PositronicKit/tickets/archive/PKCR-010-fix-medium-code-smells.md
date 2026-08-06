---
Priority: P2
Type: Code smells / hygiene
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: High
Owner: —
Effort: M
Review: Code review 2026-07-29
Pinned revision: a354632
Resolution: Completed 2026-07-29. Replaced the retry-default force try with validated failure
handling, named the streaming threshold, and extracted AnthropicStreamState and
TimelinePromptJournals. Dynamic SidecarSchemaComposer dictionaries and sorted-key encoder setup
were intentionally retained. Full verification passed with 1610 tests in 238 suites.
---

# PKCR-010 — Fix medium code smells: try! on public API, [String: Any] schemas, magic numbers, file extractions

## Summary

Several medium-severity code smells were identified:

1. **`try!` on public API** — `RetryConfiguration.default = try! RetryConfiguration()`.
2. **`[String: Any]` schema building** — `SidecarSchemaComposer.swift` uses untyped dictionaries, bypassing `JSONSchemaBuilder` guidance.
3. **Magic number `1000`** — `StreamingParser.swift:109` threshold for partial-delimiter detection.
4. **`AnthropicStreamState` trapped in `AnthropicClient.swift`** — ~100-line self-contained type that should be its own file.
5. **`TimelinePromptJournals` trapped in `TimelinePromptHistory.swift`** — ~55-line self-contained actor.
6. **`JSONEncoder` + `.sortedKeys` boilerplate** — 4 identical 2-line setups across providers.

## Current problem

- `Sources/PKUtilities/RetryConfiguration.swift:102` — `public static let default = try! RetryConfiguration()`.
- `Sources/PositronicKit/Services/Chat/SidecarSchemaComposer.swift:44,63,127,132-137` — `[String: Any]` for JSON schema building.
- `Sources/PositronicKit/Services/LLM/StreamingParser.swift:109` — `buffer.count < 1000`.
- `Sources/PKAnthropicProvider/AnthropicClient.swift:329-428` — `AnthropicStreamState` struct.
- `Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift:31-86` — `TimelinePromptJournals` actor.
- `Sources/PKOpenAIProvider/OpenAIConversions.swift:173-174`, `Sources/PKOpenRouterProvider/OpenRouterClient.swift:220-221`, `Sources/PKAnthropicProvider/AnthropicClient.swift:259-260`, `Sources/PKOllamaProvider/OllamaClient.swift:199-200` — `JSONEncoder` + `.sortedKeys`.

## Implementation requirements

1. Replace `try!` with a `precondition` + non-throwing internal factory for `RetryConfiguration.default`, or validate inline and use `// swiftlint:disable:next force_try` with a clear comment.
2. Extract `AnthropicStreamState` to `Sources/PKAnthropicProvider/AnthropicStreamState.swift`.
3. Extract `TimelinePromptJournals` to `Sources/PositronicKit/Services/Prompting/TimelinePromptJournals.swift`.
4. Replace the magic `1000` with a named private constant (e.g., `partialDelimiterThreshold`).
5. Add a shared `PKUtilities.sortedKeysJSONEncoder` constant and replace the 4 inline setups.
6. For `SidecarSchemaComposer`: if migrating to `JSONSchemaBuilder` is non-trivial, at minimum add a `// TODO: migrate to JSONSchemaBuilder` comment and file a follow-up ticket. Do not force a risky migration.
7. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [ ] `try!` on `RetryConfiguration.default` addressed (precondition or documented).
- [ ] `AnthropicStreamState.swift` extracted.
- [ ] `TimelinePromptJournals.swift` extracted.
- [ ] Magic `1000` replaced with named constant.
- [ ] `sortedKeysJSONEncoder` shared constant added and used by all 4 providers.
- [ ] `SidecarSchemaComposer` has at minimum a TODO comment if not migrated.
- [ ] `swift build` succeeds.
- [ ] `swift test` passes (1598+ tests).
- [ ] `CHANGELOG.md` updated.
