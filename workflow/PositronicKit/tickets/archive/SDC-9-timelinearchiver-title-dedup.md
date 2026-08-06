# SDC-9 — `TimelineArchiver` should call the shared `generateTitle` utility, not its own copy

**Status:** Done (landed in `PositronicKit/main` before 2026-07-04; verified against current source)
**Severity:** 🟡 Medium (duplication, inconsistent output quality)
**Repos:** PositronicKit
**Source:** Split from SDC-1 (2026-07-03 pre-sidecar simplification survey) — this part does not depend on the sidecar mechanism and can land independently.

## Problem

Title generation exists twice with different prompts, inputs, and post-processing:

- `TimelineArchiver.generateTitle(for:)` (`Sources/PositronicKit/Services/Timeline/TimelineArchiver.swift:125-141`, private) — prompt over the **first user message only**, "max 5 words", plain-text response, strips `"` by hand, falls back to a 40-char prefix.
- `LLMServiceProtocol.generateTitle(for:)` (`Sources/PositronicKit/Services/LLM/LLMService+Utilities.swift:33-65`, public) — prompt over the **full transcript**, "maximum 6 words", trims/strips quotes, falls back to `"New Conversation"`.

Same capability, two prompts, two fallback behaviors; `TimelineArchiver` doesn't call the public utility sitting on the very protocol it holds.

## Suggested direction

Delete `TimelineArchiver.generateTitle` and call `llmService.generateTitle(for: messages)`
instead; keep the archiver's prefix fallback if desired. Add a test asserting
`TimelineArchiver.archive` produces titles through the shared path (mock LLM service records
the prompt).

Do this now rather than waiting on the sidecar mechanism — SDC-1 covers the longer-term plan
of expressing this shared utility as a canonical sidecar directive descriptor once that
mechanism lands.

## Completion note

`TimelineArchiver` now resolves titles through `llmService.generateTitle(for: messages)` and
retains the first-user-message prefix fallback when the shared utility returns an empty/default
title. Coverage lives in `TimelineArchiverTests.archive_generatesTitleFromSharedUtility`.
