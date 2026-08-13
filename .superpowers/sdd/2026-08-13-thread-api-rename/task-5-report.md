# Task 5 Review Fix Round 1

## Spec Compliance

Complete after round-one fixes. The implementation makes Thread the canonical runtime, prompt, tool, workspace, error, and observable surface. Deprecated Timeline aliases/forwards are present; `timeline_list`, `timeline_peek`, `timeline_send`, `timeline_id`, serialized keys, error codes/domains/messages, and `ThreadController` streaming behavior are preserved. Actor isolation is retained for the manager, prompt journals/history, router, controller, and legacy agent-manager adapter.

`AgentInstanceManagerProtocol` now requires canonical `attach(agentID:to:threadID:)`, `detach(agentID:from:threadID:)`, and `getThreads(attachedTo:)` witnesses usable through an existential. Timeline spellings are deprecated one-way extension forwards. Existing timeline-named conformers have an isolated deprecated `TimelineAgentInstanceManagerProtocol` plus `LegacyAgentInstanceManagerAdapter` injection path. The concrete `getThreads(attachedTo:)` is canonical and not deprecated. `ThreadContext` exposes canonical `thread`/`threadTitle` and deprecated `timeline`/`timelineTitle` forwards.

## Strengths

- Canonical tool implementations use `ThreadPersistenceProtocol` directly; legacy stores are adapted only at compatibility boundaries.
- Tool call names and schemas retain the historical external contract, including `timeline_id`.
- New error cases share the legacy error codes and user-facing strings; `PKErrorDomain.thread` retains the historical timeline domain value.
- `ThreadController` preserves the prior superseding-send generation/cancellation behavior and has compatibility coverage.
- Focused verification passed: 70 tests in 10 suites, 10 shared error-surface tests, and 5 controller compatibility tests.

## Round-One Resolutions

- Canonicalized the public agent-manager protocol requirements and identifier labels.
- Added a deprecated legacy conformer protocol and one-way adapter without changing canonical runtime dispatch.
- Corrected concrete attach/detach forward diagnostics to the exact v4 text.
- Added `ThreadContext.timelineTitle` as an exact-message deprecated forward to `threadTitle`.
- Added canonical-only existential, legacy adapter, one-way forward, compatibility property, and source diagnostic audit tests.

## Assessment

Round-one review findings resolved.

## Refs

- Review range: `4d3275a..fe9ed23` (`feat: rename thread tools and observable APIs`).
- Brief: `.superpowers/sdd/2026-08-13-thread-api-rename/task-5-brief.md`.
- Review-fix verification: `swift test --filter 'CoreAPIClarityTests|ThreadControllerCompatibilityTests|TimelineControllerTests|AgentInstanceManagerTests|PromptSectionsTests|TimelineObservationToolsTests|TimelineSendToolTests|RuntimeToolPolicyFactoryTests|ToolErrorSurfacesTests'` — passed (80 tests/11 suites + 16 tests/2 suites + 5 tests/2 suites).
- `git diff --check` is clean.
