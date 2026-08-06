---
Priority: P1
Type: Privacy / data volume
Depends on: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: Confirmed
Owner: Runtime observability
Effort: M
Tranche: D (observability, API hygiene, build confidence)
Review: PKR-012
Pinned revision: 90646771bd113ae5ffa63816a18153f5fcf9dc9c
Resolution: Implemented 2026-07-28. PositronicKit `dafb401` (merged in `26dc2c5`). Added
`DiagnosticSnapshotConfiguration` with off/metadataOnly/redacted/full policies, byte limits,
truncation, and secret redaction. Default events no longer build rich snapshots; full snapshots
require explicit opt-in. Preserved `turnSnapshotData` compatibility. Added privacy/policy tests
and audited Monad, Shuttle, and Yakamoz read-only. Merged gate: 1510 tests in 222 suites.
---

# PKRR-012 — Every successful turn embeds an unconditional rich diagnostic snapshot in response metadata

## Summary
A turn snapshot (prompts, memories, generated tags, full response/reasoning, tool
data) is built and encoded on every successful turn and exposed via the
cross-provider `APIResponseMetadata` raw snapshot `Data`. Sensitive prompt/context
data is duplicated in memory and event payloads with no retention, redaction, size,
or opt-in story.

## Current problem
- `Sources/PositronicKit/Services/Chat/Stages/MessagePersistenceStage.swift:39-60` —
  a turn snapshot is built and encoded on every successful turn.
- `Sources/PositronicKit/Services/Chat/Stages/MessagePersistenceStage.swift:145-199`
  — the snapshot includes prompts, memories, generated tags, full
  response/reasoning, and tool data.
- `Sources/PKShared/SharedTypes/APIResponseMetadata.swift:5-33` — the cross-provider
  metadata type exposes raw snapshot `Data`.

## Impact
Sensitive prompt/context data is duplicated in memory and event payloads,
increasing privacy exposure, serialization cost, and UI/network pressure. There is
no retention, redaction, size, or opt-in story.

## Recommended change
Move diagnostics to an opt-in observer/telemetry sink with a policy
(`off`, `metadataOnly`, `redacted`, `full`) and byte limits. Keep normal response
metadata small. Rename the type to provider-neutral terminology.

## Acceptance criteria
- [x] Default events do not contain prompt/memory snapshots.
- [x] Full snapshots require explicit host opt-in.
- [x] Size limits and redaction tests cover secrets and large prompts.
- [x] Regression test reproduces the current unconditional snapshot before the fix.
- [x] `CHANGELOG.md` updated under Unreleased.

## Verification
`swift test` (PositronicKit + PKShared); add a privacy/snapshot-policy suite.
Public API change — audit `Monad`/`Shuttle`/`Yakamoz` metadata consumers
(Yakamoz's inspector is the primary consumer) and follow the downstream-sync
checklist. Coordinate with PKRR-013 (logging redaction).
