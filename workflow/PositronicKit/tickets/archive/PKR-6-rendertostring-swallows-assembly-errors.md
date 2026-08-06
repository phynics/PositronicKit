# PKR-6 — `renderToString()` swallows prompt-assembly validation errors via `try?`

**Status:** Done — `renderToString()` is now `async throws -> String?`; it propagates `PromptAssemblyError` from `assemblePrompt()`/`render()` instead of swallowing it via `try?`. `nil` is preserved only for the legitimate "nothing to render" case (assembly succeeded but rendered text is empty); structural failures (`duplicateSectionIDs`, `multipleUserQuerySections`) now throw. Updated all call sites (examples, README, and ~34 test call sites across `Tests/PKPromptTests` and `Tests/PositronicKitTests`) to `try await`. Added `promptRenderToStringSurfacesValidationErrors` to `Tests/PKPromptTests/Core/PromptSectionValidationTests.swift` asserting a duplicate-section-ID prompt throws via `renderToString()`. `swift test` green (630 tests); `make verify` green (docs/linkage/test gates).
**Severity:** 🟠 Medium (structural prompt bugs become silent empty prompts)
**Repos:** PositronicKit (PKPrompt)
**Source:** PositronicKit review 2026-07-02

## Problem

`Sources/PKPrompt/PromptAssembly/Prompt+assemble.swift:17-22`: `renderToString()` wraps
`assemblePrompt().render()` in `try?` and returns `nil` for both "nothing to render" and
"prompt tree is structurally invalid" (`PromptAssemblyError.duplicateSectionIDs`,
`.multipleUserQuerySections` — thrown by `PromptSection.validateAndSort`,
`PromptSection.swift:71-94`). A malformed prompt tree silently renders as empty; callers cannot
distinguish the cases and the structural bug never surfaces. Violates the repo's
PKError/ErrorKit error-surfacing convention.

## Suggested direction

Make `renderToString()` `throws` (preferred), or at minimum log the swallowed error through the
standard logging path before returning `nil`. Update callers and add a test asserting a
duplicate-ID tree surfaces the assembly error.
