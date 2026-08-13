# Thread API Rename Design

## Status

Approved for implementation on 2026-08-13.

## Goal

Make `Thread` the canonical public terminology for durable conversations in PositronicKit
while keeping the released v3 API source-compatible until the v4 cutover.

The migration is a Swift API rename, not a persistence migration. Existing serialized data,
database column names, Codable keys, and external tool call identifiers remain unchanged.

## Canonical API

The public model and runtime surface becomes thread-first. The primary renamed families are:

| v3 name | Canonical name |
| --- | --- |
| `Timeline` | `Thread` |
| `TimelineManager` | `ThreadManager` |
| `TimelineDriver` | `ThreadDriver` |
| `TimelineError` | `ThreadError` |
| `TimelineDeletionResult` | `ThreadDeletionResult` |
| `TimelinePersistenceProtocol` | `ThreadPersistenceProtocol` |
| `TimelineController` | `ThreadController` |
| `TimelinePromptHistory` | `ThreadPromptHistory` |
| `TimelinePromptJournals` | `ThreadPromptJournals` |
| `TimelineTaskRegistry` | `ThreadTaskRegistry` |
| `TimelineToolRegistry` | `ThreadToolRegistry` |
| `TimelineListTool` | `ThreadListTool` |
| `TimelinePeekTool` | `ThreadPeekTool` |
| `TimelineSendTool` | `ThreadSendTool` |
| `TimelineContext` | `ThreadContext` |

Public methods, properties, parameters, configuration members, and identifiers use the
corresponding `thread…` spelling: for example `createThread`, `openThread`, `thread(id:)`,
`listThreads`, `threadManager`, `threadPersistence`, `threadID`, and `privateThreadID`.
The implementation, examples, documentation, and tests use the canonical spelling.

Internal implementation names may be migrated in the same pass when doing so keeps the
surface coherent, but the compatibility layer is intentionally limited to public API symbols.

## Compatibility layer

Every renamed public type gets a deprecated compatibility typealias where Swift allows it:

```swift
@available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
public typealias Timeline = Thread
```

The same pattern applies to the renamed manager, driver, error, result, controller, prompt,
registry, and tool types. The old name remains usable as an alias of the canonical type, so
values, generic constraints, Codable behavior, and actor isolation remain identical.

Renamed methods and properties retain deprecated forwarding declarations with
`renamed:` diagnostics when Swift can express the migration. Forwarders must preserve the
existing behavior, labels, async/throws effects, and return types. Deprecated diagnostics use
the same v4 message and point directly to the canonical thread spelling.

Protocols require special handling. The canonical `ThreadPersistenceProtocol` owns the new
thread terminology. A deprecated compatibility surface preserves existing timeline-named
requirements and conformers through one-way forwarding/default implementations or an adapter,
so an existing v3 store can still be injected while new stores implement the thread API. The
runtime accepts both forms during v3; the compatibility protocol/adapter is removed in v4.

The old API is deprecated immediately in this release and is scheduled for removal in v4. No
deprecated shim is silently retained without a diagnostic.

## Storage and wire compatibility

The following remain stable:

- Codable keys such as `attachedWorkspaceIds` and `attachedAgentInstanceId`.
- Existing persistence schema and method behavior.
- External tool call names such as `timeline_list`, `timeline_peek`, and `timeline_send`.
- Existing error domains, error codes, and serialized payload shapes.

User-facing display strings may adopt “Thread” when they are Swift/API documentation labels,
but protocol-facing identifiers and persisted values do not change in this migration.

## Implementation sequencing

1. Add red tests for canonical thread types/methods, compatibility aliases, forwarding behavior,
   and stable Codable/tool identifiers.
2. Rename production declarations and internal call sites to the canonical thread names.
3. Add deprecated typealiases and forwarding APIs, including the persistence compatibility path.
4. Migrate observable wrappers, examples, DocC/docs, and test helpers to canonical names.
5. Add the Unreleased changelog entry documenting immediate deprecation and v4 removal.
6. Run focused tests, package/product checks, and the platform-appropriate repository gate.

## Verification

Tests must demonstrate that:

- New thread APIs compile and behave identically to the existing implementation.
- Existing timeline API call sites still compile through deprecated shims.
- Old and new persistence conformers can be used during v3 compatibility.
- Codable round trips preserve the historical keys and payload shape.
- Observable/controller and example targets compile against canonical names.
- Deprecation diagnostics direct users to the corresponding `Thread` API and mention v4.

The final report will distinguish compiler/test evidence from the known deprecation warnings
that are intentionally exercised by compatibility tests.

