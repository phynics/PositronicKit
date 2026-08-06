---
Priority: P1
Type: Code hygiene
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: High — verified by reading each file's content
Owner: —
Effort: M
Review: Code review 2026-07-29
Pinned revision: a354632
Resolution: Completed 2026-07-29. Removed verified unused PKShared, PKUtilities, ErrorKit, and
Logging imports across PKUtilities, PKPrompt, and PositronicKit; retained PKShared in PromptJournal
because it uses Message. Full verification passed with 1610 tests in 238 suites.
---

# PKCR-006 — Clean unused imports (~26 files)

## Summary

Approximately 26 source files across `PKUtilities`, `PKPrompt`, and `PositronicKit` have unused `import` statements for `PKShared`, `PKUtilities`, `ErrorKit`, and `Logging`.

## Current problem

**Unused `import PKShared` in PKUtilities (9 files):**
- `Sources/PKUtilities/ANSIColors.swift`
- `Sources/PKUtilities/StableHash.swift`
- `Sources/PKUtilities/CancellableAsyncThrowingStream.swift`
- `Sources/PKUtilities/LimitedErrorBodyCollector.swift`
- `Sources/PKUtilities/LogRedaction.swift`
- `Sources/PKUtilities/Pipeline+Logging.swift`
- `Sources/PKUtilities/TokenEstimator.swift`
- `Sources/PKUtilities/Logger+Extensions.swift`
- `Sources/PKUtilities/Filesystem/FilesystemSearchLimits.swift`

**Unused `import PKShared` + `import PKUtilities` in PKPrompt (12 files):**
- `Sources/PKPrompt/Support/Collection+UniqueIDs.swift`
- `Sources/PKPrompt/PromptAssembly/RenderedPrompt.swift`
- `Sources/PKPrompt/Journal/SectionContentHash.swift`
- `Sources/PKPrompt/Journal/PromptJournal.swift`
- `Sources/PKPrompt/PromptBuilder/Prompts/EmptyPrompt.swift`
- `Sources/PKPrompt/PromptBuilder/Structural/PromptTuple.swift`
- `Sources/PKPrompt/PromptBuilder/Builder/Section/PromptSection.swift`
- `Sources/PKPrompt/PromptBuilder/Builder/Node/TextPromptPrimitive.swift`
- `Sources/PKPrompt/PromptBuilder/Builder/Prompt/AnyPrompt.swift`
- `Sources/PKPrompt/PromptBuilder/Builder/Prompt/PromptModifiers.swift`
- `Sources/PKPrompt/PromptBuilder/Builder/Section/PromptSection+Convenience.swift`
- `Sources/PKPrompt/PromptAssembly/RenderedPrompt+Section.swift`

**Unused `import PKUtilities` only in PKPrompt (5 files):**
- `Sources/PKPrompt/PromptAssembly/AssembledPrompt.swift`
- `Sources/PKPrompt/PromptBuilder/Builder/PromptAssemblyError.swift`
- `Sources/PKPrompt/PromptBuilder/Prompts/HistoryPrompt.swift`
- `Sources/PKPrompt/PromptBuilder/Builder/Section/PromptSection+Content.swift`
- `Sources/PKPrompt/Journal/PromptJournalPlan+Messages.swift`

**Unused `import ErrorKit` (4 files):**
- `Sources/PositronicKit/PositronicKit.swift`
- `Sources/PKUtilities/RetryPolicy.swift`
- `Sources/PositronicKit/Services/Context/Pipeline/Stages/NoteDiscoveryStage.swift`
- `Sources/PositronicKit/Services/LLM/LLMService.swift`

**Unused `import Logging` (2 files):**
- `Sources/PositronicKit/Models/Tools/ToolContext/ToolContext.swift` (will be deleted by PKCR-001)
- `Sources/PositronicKit/Services/Workspace/DefaultWorkspaceResolver.swift`

## Implementation requirements

1. Remove the unused `import` lines from each file listed above.
2. After each batch removal, run `swift build` to verify no hidden dependency (protocol witness table, macro expansion, result builder visibility).
3. Skip `ToolContext.swift` — it will be deleted by PKCR-001.
4. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [ ] All listed unused imports removed.
- [ ] `swift build` succeeds after each batch.
- [ ] `swift test` passes (1598+ tests).
- [ ] `CHANGELOG.md` updated.
