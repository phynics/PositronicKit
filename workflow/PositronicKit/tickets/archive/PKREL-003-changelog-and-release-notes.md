# PKREL-003: Add CHANGELOG and Write v1.0.0 Release Notes

**Priority:** P2
**Type:** Documentation / release mechanics
**Depends on:** PKREL-002
**Blocks:** PKREL-004
**Status:** Done (2026-07-05)

### Summary

Introduce a `CHANGELOG.md` (Keep a Changelog format) at the PositronicKit repo root and write
the `1.0.0` entry. With three downstream consumers and a semver pin coming, a changelog is the
contract that lets consumers upgrade without reading diffs.

### Required Content for the 1.0.0 Entry

- Product/module map (core, PKPrompt, PKShared, PKLocalEmbeddings, three providers,
  PKTestSupport, Examples) and the platform support matrix, matching PKDOC-004's published
  contract.
- Highlights: prompt DSL + journaling, ChatEngine pipeline and plugins, sidecar directives,
  structured output, tool routing with approval gates, local embeddings (Apple NL + MiniLM),
  `ChatRunRequest` API.
- Known limitations: no native Anthropic adapter (per the PKREL-002 decision), PKINT-003 and
  PKINT-007 status, Apple NL vs MiniLM vector incompatibility.
- Migration notes for anything renamed/removed during the PKREL-002 freeze.

### Acceptance Criteria

- [x] `CHANGELOG.md` exists with an `Unreleased` section template and a complete `1.0.0` entry.
- [x] README links to the changelog.
- [x] Release-notes text is ready to paste into the GitHub release for the tag.

### Resolution

Done in workspace changes on 2026-07-05 (`commit pending`). Added a Keep a Changelog-formatted
`CHANGELOG.md` with an `Unreleased` template plus a full `1.0.0` entry covering the product map,
support matrix, highlights, known limitations, migration notes, and paste-ready release notes;
updated the README to link to the changelog. Verification: `make verify` passed in
`PositronicKit` after the docs changes.
