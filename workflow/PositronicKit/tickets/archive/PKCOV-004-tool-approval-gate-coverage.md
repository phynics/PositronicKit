# PKCOV-004 — `ToolApprovalGate` enforcement coverage across filesystem tools

**Priority:** P3
**Type:** Test coverage
**Depends on:** —
**Blocks:** —
**Triage:** ready-for-agent
**Status:** Done (2026-07-09, commit `9ba7b6d`) — added
`Tests/PositronicKitTests/Services/ToolApprovalGateFilesystemToolsTests.swift`. Confirmed and
documented (in the file header) that enforcement lives in `ToolRouter` (`PositronicKit`), not in
`PKShared`'s `ToolApprovalGate.swift` itself (which only defines the protocol + two default gates).
Parameterized `@Test(arguments:)` across the 5 permissioned filesystem tools (`cat`/`ls`/`find`/
`search_files`/`grep`), backed by a guard test asserting each listed tool's `requiresPermission ==
true` so a future flag flip degrades loudly rather than silently. `ChangeDirectoryTool`
(`requiresPermission == false`) gets an explicit dedicated test proving the gate is never even
consulted (`gate.consultedToolIds.isEmpty`), not just implied by omission. Default posture
(`ToolRouter`'s own default `DenyAllToolApprovalGate`, no gate injected) is pinned. `ToolError
.permissionDenied(_:).errorCode == 210` is pinned as the stable denial error code. No production
source touched — test-only. `swift test`: 908 tests / 158 suites green.

### Summary

`Sources/PKShared/Tools/ToolApprovalGate.swift` has no tests asserting that approval
gating is actually enforced across the PKShared filesystem tools
(`ChangeDirectoryTool`, `FindFileTool`, `ListDirectoryTool`, `ReadFileTool`,
`SearchFilesTool`, `SearchFileContentTool`). This is a permission/safety surface;
regressions would silently grant tool access.

### Implementation Requirements

1. Add tests in `Tests/PKSharedTests/Tools/` (or alongside `ToolRouterTests` if the gate
   is enforced at routing level — verify where enforcement actually lives first and
   document it in the test file header):
   - denied approval blocks execution and surfaces the expected error shape,
   - granted approval executes,
   - default posture (no gate configured) is pinned explicitly.
2. Parameterize across the filesystem tools rather than testing one representative, so
   a newly added tool missing gate enforcement fails a test.

### Acceptance Criteria

- [x] Gate enforcement pinned for every current filesystem tool.
- [x] Denial error shape asserted (PKError code stable).
- [x] `make verify` green.
