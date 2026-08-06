# PositronicKit Swift API Guidelines Remediation

Pinned revision: `ebd61d5` (`3.3.0`)

## Goal

Apply the high-confidence findings from the 2026-08-04 Swift API Design Guidelines
review without breaking the 3.x source or serialized-data compatibility contract.

## Global constraints

- Add clear canonical APIs and retain deprecated forwarding shims for existing public APIs.
- Preserve existing Codable keys explicitly when Swift identifier casing changes.
- Update declarations and representative call sites together, including examples and tests.
- Audit Monad, Shuttle, and Yakamoz for every changed public symbol; also audit LandGo as a
  prerelease consumer.
- Add or update tests for forwarding behavior, wire compatibility, and canonical call shapes.
- Update `CHANGELOG.md` under `Unreleased`.
- Do not introduce duplicate semantic enum cases merely to label associated values; record the
  `PKFastEmbedError` label cleanup as major-release work instead.

## Tasks

1. `PKAPI-001`: Core identifier casing, query names, factories, vector labels, and complexity docs.
2. `PKAPI-002`: PKPrompt truncation/reset/ForEach/token-budget/node-ID fluency.
3. `PKAPI-003`: Provider factory naming, cross-platform MiniLM label, Foundation Models closure
   roles, and PKTestSupport facade access.
4. Integrate reviewed commits, run downstream audits, prepare the release changelog, and run the
   full release gates.

