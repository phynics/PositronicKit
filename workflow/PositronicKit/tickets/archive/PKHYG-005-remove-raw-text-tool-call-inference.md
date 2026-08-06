# PKHYG-005 — Remove raw-text tool-call inference

**Priority:** P1
**Type:** Security / behavior change
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done

**Resolution (2026-07-12):** Consumer audit confirmed no downstream references to
`ToolOutputParser` in Monad, Shuttle, or Yakamoz. Deleted `ToolOutputParser.swift` and its
dedicated tests. Removed the fallback parse/synthetic accumulator/event block in
`ToolCallExtractionStage`. Updated 2 existing tests that expected fallback behavior to assert
no tool calls are produced from legacy text. Added 3 replacement tests proving XML markers,
pipe-delimited markers, and fenced JSON do not produce accumulators. `ToolOutputParser` and
its tests are gone. CHANGELOG updated with Unreleased migration note. 948 tests green.
PositronicKit `4a9a59d`.

## Summary

Restrict executable tool calls to provider-native structured call deltas; assistant text containing legacy XML, pipe markers, or fenced JSON remains ordinary content.

## Current Problem

- `Sources/PositronicKit/Services/Chat/Stages/ToolCallExtractionStage.swift:51-79` calls `ToolOutputParser` when no structured calls were received and tools are available.
- `Sources/PositronicKit/Utilities/ToolOutputParser.swift` recognizes Qwen-style markers, `<tool_call>` XML, and lenient fenced JSON, converting generated text into executable call accumulators.
- The `availableTools` guard reduces accidental execution, but a broad inference path remains and complicates the execution contract.

## Implementation Requirements

- Before code changes, search Monad, Shuttle, and Yakamoz for raw-text/non-native tool-call usage and record results in this ticket's implementation notes.
- If a consumer requires a raw-text tool format, stop and design that consumer's migration; do not delete fallback behavior until its replacement is agreed.
- Delete `ToolOutputParser`, its dedicated tests, and the fallback parse/synthetic accumulator/event block in `ToolCallExtractionStage`.
- Preserve provider-native structured `toolCallAccumulators`, sentinel/empty cleanup, debug recording, and `ToolApprovalGate` behavior.
- Replace the fenced-JSON recovery regression with tests proving each legacy textual format produces no tool call or accumulator even when tools are available.
- Add an Unreleased CHANGELOG migration note: models must emit provider-native structured calls; raw text is not executable.

## Acceptance Criteria

- [ ] Consumer audit results are recorded before deletion.
- [ ] XML, pipe-marker, and fenced-JSON assistant content never produces `ChatEvent.toolCall` or a tool accumulator.
- [ ] Provider-native structured calls continue to execute through the existing approval path.
- [ ] `ToolOutputParser.swift` and its dedicated tests are gone.
- [ ] `swift test` and `make verify` pass; CHANGELOG documents the behavior change.

