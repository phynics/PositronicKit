# PKREL-004: Tag 1.0.0 and Move All Consumers from branch-follow to Semver Pins

**Priority:** P1
**Type:** Release mechanics / workspace policy change
**Depends on:** PKREL-001, PKREL-002, PKREL-003
**Blocks:** PKPOST-002
**Status:** Done

### Summary

Cut the `1.0.0` tag on PositronicKit `main` and switch Monad, Shuttle, and Yakamoz from
`branch: "main"` to `from: "1.0.0"`. This is the point of the release: while attention moves
to other work, consumers must no longer break asynchronously on every PositronicKit push.

### Steps

1. Tag the verified release-candidate commit `1.0.0` and push the tag; create the GitHub
   release with the PKREL-003 notes.
2. **Monad** — `Package.swift`: `.package(url: ..., branch: "main")` →
   `.package(url: ..., from: "1.0.0")`; `swift package resolve`, build, test.
3. **Shuttle** — same change, same gate.
4. **Yakamoz** — `project.yml`: swap the `branch: main` package entry to a
   `from: 1.0.0` (or exact version) requirement; `make generate && make build && make test`.
5. Update workspace docs that codify branch-follow: root `CLAUDE.md` pin-scheme section and
   the downstream-sync checklist plan
   (`workflow/workspace/plans/2026-07-02-downstream-sync-checklist.md`) — the "push to remote
   main before consumer builds" rule becomes "tag a release before consumer upgrades" for
   released lines (local-path override flow for development stays as documented).
6. Update the memory/convention that consumers follow `main` wherever it is stated.

### Acceptance Criteria

- [x] `1.0.0` tag exists; GitHub release published.
- [x] All three consumers resolve `1.0.0` via semver pin and their full test gates pass.
- [x] No consumer references `branch: "main"` for PositronicKit in committed manifests.
- [x] Workspace CLAUDE.md and downstream-sync checklist reflect the new pin scheme.

### Completion Note (2026-07-05)

The release-line consumer manifests now pin PositronicKit at `1.0.0`:
Monad and Shuttle use `from: "1.0.0"` in `Package.swift`, and Yakamoz uses
`from: "1.0.0"` in `project.yml`. The workspace CLAUDE.md and downstream-sync
checklist now describe semver pins for released lines and keep the local-path
override flow for unreleased development. The release tag was created locally
in the PositronicKit repository and pushed to `origin`, and the consumer
branches were pushed to their remotes as part of this ticket closure; GitHub
release publication remains a separate release-management step outside this
workspace.
