# PKV3-009 — Split public PKUtilities from PKShared

**Priority:** P1
**Type:** Module architecture
**Depends on:** —
**Blocks:** PKV3-006, PKV3-011
**Triage:** ready-for-agent
**Status:** Done (2026-07-13, PositronicKit `8c89069`, merged to `main` via `347e554`)

**Resolution:** Added public `PKUtilities` library product/target depending only on `PKShared`
(confirmed no `PKShared` → `PKUtilities` edge). Moved observability (`RetryPolicy`,
`ProviderHTTPFailure`/`ProviderHTTPTransport`, `LogKeys`, `LogRedaction`,
`Logger+Extensions`), async/pipeline helpers (`Pipeline`, `Pipeline+Logging`,
`CancellableAsyncThrowingStream`, `Collection+UniqueIDs`), `StableHash`, `TokenEstimator`,
`PathSanitizer`, `LimitedErrorBodyCollector`, `ANSIColors`, and the concrete filesystem tools
(`ReadFileTool`, `FindFileTool`, `ListDirectoryTool`, `SearchFileContentTool`, `SearchFilesTool`,
`ChangeDirectoryTool`, `FilesystemToolSupport`, `FilesystemSearchLimits`) into `PKUtilities`.
`PKShared` retains contracts/errors/schemas/domain types/`Tool` contracts. Test targets migrated
to a new `PKUtilitiesTests` target. Landed together with PKV3-001/008/011 as PKV3 Track 1;
`swift build`/`swift test` clean post-merge (963/963, 167 suites).

## Summary

Create public PKUtilities for cross-cutting observability, helpers, and filesystem-tool implementations; keep PKShared as the contracts/types/schema module.

## Implementation Requirements

- Add public `PKUtilities` product/target depending on `PKShared`.
- Move observability, logging/redaction, async/pipeline helpers, and concrete filesystem tools into PKUtilities.
- Keep shared contracts, errors, schemas, domain types, and Tool contracts in PKShared.
- Update imports and package dependencies without introducing a PKShared → PKUtilities edge.
- Migrate package consumers and relevant downstream imports.

## Acceptance Criteria

- [ ] PKUtilities is a public library product.
- [ ] PKShared does not import PKUtilities.
- [ ] Filesystem tools and observability compile from PKUtilities.
- [ ] Package and downstream gates pass.

