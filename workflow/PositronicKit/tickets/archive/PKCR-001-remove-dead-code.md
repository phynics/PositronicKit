---
Priority: P0
Type: Dead code removal
Depends: —
Blocks: —
Triage: ready-for-agent
Status: Done
Confidence: High — verified zero references across PositronicKit, Monad, Shuttle, Yakamoz, LandGo
Resolution: Completed 2026-07-29. Removed the unadopted ToolContext subsystem, TurnBriefing
typealias, PromptHistorySectionKind.synthetic case, and unread PromptSectionEntry.sectionKind.
PositronicKit build and 1598-test suite passed.
Owner: —
Effort: S
Review: Code review 2026-07-29
Pinned revision: a354632
---

# PKCR-001 — Remove dead code: ToolContext subsystem, TurnBriefing typealias, PromptHistorySectionKind.synthetic

## Summary

Three pieces of dead code were identified in the code review:

1. **`ToolContext` protocol + `ToolTimelineContext`** — an entire subsystem with zero conformances and zero callers across all repos.
2. **`TurnBriefing` typealias** — declared but never referenced anywhere.
3. **`PromptHistorySectionKind.synthetic` case + `PromptSectionEntry.sectionKind` property** — the enum case is never constructed; the property is written but never read.

## Current problem

- `Sources/PositronicKit/Models/Tools/ToolContext/ToolContext.swift:8` — `public protocol ToolContext: AnyObject, Sendable` has zero conforming types.
- `Sources/PositronicKit/Models/Tools/ToolContext/ToolTimelineContext.swift:27-101` — `activate()`, `forceDeactivate()`, `isContextTool()`, `isActiveContextGateway()`, `activeContextId`, `isActiveContextPersistent` — none are ever called. Since `activate()` is never called, `hasActiveContext` is always `false` and `getContextTools()` always returns `[]`.
- `Sources/PositronicKit/Services/Context/ContextData.swift:38` — `public typealias TurnBriefing = ContextData` has zero references.
- `Sources/PositronicKit/Services/Prompting/TimelinePromptHistoryTypes.swift:43` — `.synthetic` case never constructed.
- `Sources/PositronicKit/Services/Prompting/TimelinePromptHistoryTypes.swift:33` — `sectionKind` property written but never read.

## Implementation requirements

1. Delete `Sources/PositronicKit/Models/Tools/ToolContext/ToolContext.swift`.
2. Delete `Sources/PositronicKit/Models/Tools/ToolContext/ToolTimelineContext.swift`.
3. Remove the `toolContextTimeline` property and any references in `TimelineManager` or `ChatEngine` (search for `ToolTimelineContext` and `toolContextTimeline`).
4. Remove the `TurnBriefing` typealias from `ContextData.swift`.
5. Remove the `.synthetic` case from `PromptHistorySectionKind`.
6. Remove the `sectionKind` property from `PromptSectionEntry` and its assignment at `TimelinePromptHistory.swift:172`.
7. Update `CHANGELOG.md` under `Unreleased`.

## Acceptance criteria

- [ ] `ToolContext.swift` and `ToolTimelineContext.swift` deleted.
- [ ] `TurnBriefing` typealias removed.
- [ ] `.synthetic` case and `sectionKind` property removed.
- [ ] No remaining references to any of the above in Sources/ or Tests/.
- [ ] `swift build` succeeds.
- [ ] `swift test` passes (1598+ tests).
- [ ] `CHANGELOG.md` updated.
