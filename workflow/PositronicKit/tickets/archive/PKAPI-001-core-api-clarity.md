---
Priority: P1
Type: API design
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Resolution: Completed 2026-08-04 in PositronicKit 7aeb3ca. Added source-compatible canonical
  APIs, preserved legacy wire keys, migrated ordinary call sites, and verified the 3.4.0 release gates.
Confidence: High
Owner: —
Effort: L
Review: Swift API Design Guidelines review 2026-08-04
Pinned revision: ebd61d5
---

# PKAPI-001 — Improve core API clarity and consistency

## Summary

Introduce source-compatible canonical names for inconsistent `Id` identifiers, Java-style query
methods, factory methods that do not begin with `make`, and same-typed vector arguments. Preserve
wire formats and retain deprecated forwarding APIs.

## Current problem

- `VectorMath.cosineSimilarity(_:_:)` (`Sources/PositronicKit/Utilities/VectorMath.swift:13`)
  takes two indistinguishable `[Double]` values.
- Public contracts mix `Id` and `ID`, including `ChatRunRequest`, `Message`, and `Timeline`, while
  related types already use `timelineID` and `toolCallID`.
- Query APIs use `get…`: `LLMService.getClient/getUtilityClient/getFastClient`,
  `WorkspaceResolver.getWorkspace(id:)`, and `AgentInstanceManager.getInstance/getTimelines`.
- Factories omit `make`: `ProviderConfiguration.defaultFor(_:)`,
  `LoggingMetadata.forError(_:correlationID:)`, and
  `WorkspaceReference.primaryForTimeline(_:rootPath:)`.
- `PromptSections.ChatHistory.estimatedTokens` is non-constant without a complexity note.

## Implementation requirements

1. Add `cosineSimilarity(between:and:)`; deprecate and forward the positional overload.
2. Audit exported stored-model properties and initializer labels ending in `Id`/`Ids`; add
   canonical `ID`/`IDs` spellings, deprecated aliases/forwarding initializers, and explicit
   `CodingKeys` preserving existing keys. Do not change stored wire keys. PKPrompt `nodeId` models
   are owned by PKAPI-002. The broader protocol/method parameter-label sweep is tracked separately
   by PKAPI-004 and does not block this compatibility-focused release.
3. Add noun/query canonical APIs (`client`, `utilityClient`, `fastClient`, `workspace(id:)`,
   `instance(id:)`, `timelines(attachedTo:)`) and retain deprecated forwarding methods. Keep
   protocol conformers source-compatible through default implementations where needed.
4. Add `makeDefault(for:)`, `makeMetadata(for:correlationID:)`, and
   `makePrimary(forTimeline:rootPath:)`; deprecate old factories.
5. Document `estimatedTokens` complexity.
6. Update PositronicKit sources, examples, tests, and all affected downstream call sites.
7. Add tests for compatibility shims and serialized-key stability.
8. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [x] Canonical call sites follow Swift acronym, query, factory, and argument-label guidance.
- [x] Existing public call shapes still compile through deprecated forwarding APIs.
- [x] Existing serialized keys remain unchanged.
- [x] PositronicKit focused tests pass.
- [x] Monad, Shuttle, Yakamoz, and LandGo symbol audits are recorded.
- [x] `CHANGELOG.md` is updated.

## Verification and downstream audit

- `make verify`: passed, 1,637 tests in 242 suites.
- `make verify-products`, `make verify-minilm`, and `make verify-linux-current`: passed.
- Monad, Shuttle, Yakamoz, and LandGo were searched for affected symbols. Their released pins do
  not expose these new canonical APIs, and the forwarding shims preserve existing calls, so no
  downstream edit was required. No persisted field was added; explicit `CodingKeys` preserve the
  existing keys, so Monad needs no GRDB migration.
