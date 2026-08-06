# SDC-1 — Two divergent title-generation implementations

**Status:** Done (short-term fix landed via SDC-9 on 2026-07-04; the "one canonical title
directive descriptor" half of this ticket is superseded by Yakamoz ticket SID-1
`workflow/Yakamoz/tickets/SID-1-title-directive-with-cadence.md`, tracked there since directive
ownership lives in YakamozCore per the sidecar spec's ownership split)
**Severity:** 🟡 Medium (duplication, inconsistent output quality)
**Repos:** PositronicKit
**Source:** 2026-07-03 pre-sidecar simplification survey

## Problem

Title generation exists twice with different prompts, inputs, and post-processing:

- `TimelineArchiver.generateTitle(for:)` (`Sources/PositronicKit/Services/Timeline/TimelineArchiver.swift:125-141`, private) — prompt over the **first user message only**, "max 5 words", plain-text response, strips `"` by hand, falls back to a 40-char prefix.
- `LLMServiceProtocol.generateTitle(for:)` (`Sources/PositronicKit/Services/LLM/LLMService+Utilities.swift:33-65`, public) — prompt over the **full transcript**, "maximum 6 words", trims/strips quotes, falls back to `"New Conversation"`.

Same capability, two prompts, two fallback behaviors; `TimelineArchiver` doesn't call the public utility sitting on the very protocol it holds.

## Suggested direction

After the sidecar mechanism lands, define **one** canonical title directive descriptor
(name/instruction/schema — see SDC-2) and have both paths consume it, so the one-shot utility
and any piggy-backed `title` sidecar share the same directive definition and prompt
wording/length policy lives in exactly one place.

The independent short-term fix (deleting `TimelineArchiver.generateTitle` in favor of calling
`llmService.generateTitle` directly, with a test) does not need to wait on sidecars — see
**SDC-9**, split out so it can land now.
