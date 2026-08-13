# Thread API Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Thread` the canonical PositronicKit public API while keeping all released v3 `Timeline` names source-compatible but deprecated until v4.

**Architecture:** Rename the production symbols and internal call sites to thread-first names. Keep storage and wire identifiers unchanged. Add module-owned compatibility files containing deprecated typealiases and forwarding declarations; use a dedicated legacy persistence adapter because protocol conformance cannot be preserved by a typealias when requirement labels change.

**Tech Stack:** Swift 6.1+, Swift Package Manager, Swift Testing, Swift Codable, Swift actors, DocC, and the repository’s native macOS `make verify` gate.

## Global Constraints

- Existing serialized keys, database schema, error codes/domains, and external tool call names remain unchanged.
- The canonical public terminology is `Thread`; old `Timeline` APIs are deprecated immediately and removed at v4.
- Deprecated diagnostics use: `Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.`
- Existing v3 persistence conformers remain injectable through the compatibility protocol/adapter path.
- Production code uses `Thread` names internally; compatibility shims are isolated and one-way.
- Do not add network, persistence, or provider dependencies.
- New behavior is implemented test-first: each task writes a failing test, runs it, implements the minimum change, and reruns the focused test.
- On this macOS checkout, use native Swift and finish with `make verify`; Linux verification, if needed, uses `make agent-verify`.

---

## File and module map

The following existing files contain the public or runtime timeline surface and are grouped by responsibility. Keep their current paths unless a file move materially improves the resulting module; symbol names and documentation must become canonical regardless of file spelling.

Core model and persistence:

- `Sources/PositronicKit/Models/Database/Timeline.swift`
- `Sources/PositronicKit/Models/Database/ConversationMessage.swift`
- `Sources/PositronicKit/Services/Database/TimelinePersistenceProtocol.swift`
- `Sources/PositronicKit/Services/Storage/InMemoryTimelinePersistence.swift`
- `Sources/PositronicKit/PositronicKit+Configuration.swift`
- `Sources/PositronicKit/PositronicKit+Dependencies.swift`
- `Sources/PositronicKit/PositronicKit.swift`
- `Sources/PositronicKit/TimelineDriver.swift`
- `Sources/PositronicKit/AgenticRuntime.swift`
- `Sources/PositronicKit/ChatRunRequest.swift`

Runtime lifecycle, context, and tools:

- `Sources/PositronicKit/Services/Timeline/TimelineManager.swift`
- `Sources/PositronicKit/Services/Timeline/TimelineManager+Init.swift`
- `Sources/PositronicKit/Services/Timeline/TimelineManager+Lifecycle.swift`
- `Sources/PositronicKit/Services/Timeline/TimelineManager+Attachments.swift`
- `Sources/PositronicKit/Services/Timeline/TimelineManagerTypes.swift`
- `Sources/PositronicKit/Services/Timeline/TimelineArchiver.swift`
- `Sources/PositronicKit/Services/Timeline/TimelineTaskRegistry.swift`
- `Sources/PositronicKit/Services/Timeline/TimelineToolRegistry.swift`
- `Sources/PositronicKit/Services/Timeline/RuntimeToolPolicyFactory.swift`
- `Sources/PositronicKit/Services/Tools/Timeline/TimelineListTool.swift`
- `Sources/PositronicKit/Services/Tools/Timeline/TimelinePeekTool.swift`
- `Sources/PositronicKit/Services/Tools/Timeline/TimelineSendTool.swift`
- `Sources/PositronicKit/Services/Tools/ToolRouter.swift`
- `Sources/PositronicKit/Services/Chat/ChatEngine.swift`
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnLoop.swift`
- `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift`
- `Sources/PositronicKit/Services/Chat/ChatTurnContext.swift`
- `Sources/PositronicKit/Services/Prompting/PromptAssembler.swift`
- `Sources/PositronicKit/Services/Prompting/DefaultInstructions.swift`
- `Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift`
- `Sources/PositronicKit/Services/Prompting/TimelinePromptHistoryTypes.swift`
- `Sources/PositronicKit/Services/Prompting/TimelinePromptJournals.swift`
- `Sources/PositronicKit/Services/Prompting/Sections/PromptSections.swift`

Shared and observable public models:

- `Sources/PKShared/SharedTypes/AgentInstance.swift`
- `Sources/PKShared/SharedTypes/TurnSnapshot.swift`
- `Sources/PKShared/SharedTypes/WorkspaceReference.swift`
- `Sources/PKShared/SharedTypes/WorkspaceURI.swift`
- `Sources/PKShared/Tools/ToolError.swift`
- `Sources/PKShared/Utilities/PKError.swift`
- `Sources/PKPrompt/Journal/AppendPressure.swift`
- `Sources/PKPrompt/Journal/PromptJournalCompactionThresholds.swift`
- `Sources/PKObservable/TimelineController.swift`

Supporting public protocols, agents, workspace configuration, and examples:

- `Sources/PositronicKit/Protocols/PromptSectionProviding.swift`
- `Sources/PositronicKit/Protocols/ChatTurnPlugin.swift`
- `Sources/PositronicKit/Protocols/PromptObserving.swift`
- `Sources/PositronicKit/Services/Agents/AgentInstanceManager.swift`
- `Sources/PositronicKit/Services/Agents/AgentInstanceManagerProtocol.swift`
- `Sources/PositronicKit/Services/Agents/AgentInstanceError.swift`
- `Sources/PositronicKit/Services/Workspace/WorkspaceResolverFactory.swift`
- `Sources/PositronicKit/Models/Workspace/WorkspaceProfile.swift`
- `Sources/PositronicKit/Services/Storage/InMemoryAgentInstanceStore.swift`
- `Sources/PositronicKit/Services/Tools/ToolTimeoutEnforcer.swift`
- `Sources/PositronicKitExamples/PositronicKitUsageExamples.swift`
- `Sources/PositronicKitExamples/main.swift`

Compatibility files to create:

- `Sources/PositronicKit/Compatibility/TimelineAPICompatibility.swift`
- `Sources/PKShared/Compatibility/TimelineAPICompatibility.swift`
- `Sources/PKObservable/Compatibility/TimelineAPICompatibility.swift`

---

### Task 1: Add failing canonical and compatibility API tests

**Files:**
- Create: `Tests/PositronicKitTests/ThreadAPICompatibilityTests.swift`
- Create: `Tests/PKSharedTests/ThreadIdentifierCompatibilityTests.swift`
- Create: `Tests/PKObservableTests/ThreadControllerCompatibilityTests.swift`
- Test fixtures: `Tests/PKTestSupport/MockTimelinePersistence.swift`, `Tests/PKTestSupport/TestRuntime.swift`

**Interfaces:**
- Consumes the current `TestRuntime`, `MockTimelinePersistence`, `PositronicKit`, and `PKObservable` test fixtures.
- Produces the compile/runtime contract for `Thread`, `ThreadManager`, `ThreadDriver`, `ThreadPersistenceProtocol`, `ThreadController`, and their deprecated timeline spellings.

- [ ] **Step 1: Write the failing tests**

Add tests with these behaviors:

```swift
@Test("the canonical thread facade creates and opens a thread")
func canonicalThreadFacade() async throws {
    let runtime = TestRuntime(workspaceRoot: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString))
    let kit = runtime.positronicKit

    let thread = try await kit.threadManager.createThread(title: "Canonical")
    let driver = kit.openThread(thread.id)

    #expect(thread.title == "Canonical")
    #expect(driver.threadID == thread.id)
}

@Test("the timeline typealias preserves value compatibility")
func legacyTimelineTypealias() {
    let thread = Thread(title: "Legacy")
    let timeline: Timeline = thread

    #expect(timeline.id == thread.id)
    #expect(timeline.title == thread.title)
}

@Test("canonical Codable keeps historical persistence keys")
func canonicalCodableKeepsHistoricalKeys() throws {
    let thread = Thread(attachedWorkspaceIDs: [UUID()], attachedAgentInstanceID: UUID())
    let data = try JSONEncoder().encode(thread)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["attachedWorkspaceIds"] != nil)
    #expect(object["attachedAgentInstanceId"] != nil)
    #expect(object["attachedWorkspaceIDs"] == nil)
}
```

Add a legacy-only persistence conformer that implements `saveTimeline`, `fetchTimeline`,
`fetchAllTimelines`, `deleteTimeline`, and `pruneTimelines`, then assert that the canonical
configuration can wrap/inject it. Add a `ThreadController` test that sends through
`kit.openThread(_:)`, proving the observable surface no longer requires `TimelineDriver`.

Mark the private compatibility test helpers `@available(*, deprecated)` so exercising old names
does not pollute the ordinary build with expected warnings.

- [ ] **Step 2: Run the focused tests and verify the expected failure**

Run:

```bash
swift test --filter ThreadAPICompatibilityTests
```

Expected: compilation fails because `Thread`, `threadManager`, `createThread`, `openThread`,
`threadID`, and `ThreadController` do not exist yet. Do not change the tests to make the current
timeline API pass; this is the red test for the rename.

- [ ] **Step 3: Commit the red tests**

```bash
git add Tests/PositronicKitTests/ThreadAPICompatibilityTests.swift \
  Tests/PKSharedTests/ThreadIdentifierCompatibilityTests.swift \
  Tests/PKObservableTests/ThreadControllerCompatibilityTests.swift
git commit -m "test: define thread API compatibility contract"
```

---

### Task 2: Rename the canonical model, persistence protocol, and durable identifiers

**Files:**
- Modify: `Sources/PositronicKit/Models/Database/Timeline.swift`
- Modify: `Sources/PositronicKit/Models/Database/ConversationMessage.swift`
- Modify: `Sources/PositronicKit/Services/Database/TimelinePersistenceProtocol.swift`
- Modify: `Sources/PositronicKit/Services/Storage/InMemoryTimelinePersistence.swift`
- Modify: `Sources/PositronicKit/Services/Storage/InMemoryAgentInstanceStore.swift`
- Modify: `Sources/PKShared/SharedTypes/AgentInstance.swift`
- Modify: `Sources/PKShared/SharedTypes/TurnSnapshot.swift`
- Modify: `Sources/PKShared/SharedTypes/WorkspaceURI.swift`
- Modify: `Sources/PKShared/SharedTypes/WorkspaceReference.swift`
- Modify: `Sources/PKShared/Utilities/PKError.swift`
- Create: `Sources/PositronicKit/Compatibility/TimelineAPICompatibility.swift`
- Create: `Sources/PKShared/Compatibility/TimelineAPICompatibility.swift`
- Test: `Tests/PositronicKitTests/ThreadAPICompatibilityTests.swift`
- Test: `Tests/PKSharedTests/ThreadIdentifierCompatibilityTests.swift`

**Interfaces:**
- Consumes the red tests from Task 1.
- Produces `Thread`, `ThreadPersistenceProtocol`, `InMemoryThreadPersistence`, `threadID`, `privateThreadID`, `threadWorkspace`, and canonical shared error-domain/enum names.

- [ ] **Step 1: Extend the red tests for identifiers and legacy Codable behavior**

Assert the following exact mappings:

```swift
let thread = Thread(title: "Stable", attachedWorkspaceIDs: [workspaceID])
let message = ConversationMessage(threadID: thread.id, role: .user, content: "Hi")
let snapshot = TurnSnapshot(
    threadID: thread.id,
    modelName: "test-model",
    turnCount: 0,
    maxTurns: 1
)

#expect(message.threadID == thread.id)
#expect(snapshot.threadID == thread.id)
#expect(WorkspaceURI.threadWorkspace(thread.id).rawValue ==
        WorkspaceURI.timelineWorkspace(thread.id).rawValue)
```

Keep JSON assertions on `timelineId`, `privateTimelineId`, and `runtimeTimeline` unchanged.
Add a legacy `TimelinePersistenceProtocol` actor conformer and a canonical
`ThreadPersistenceProtocol` actor conformer to the test support fixture.

- [ ] **Step 2: Run the focused tests and verify they fail for missing canonical declarations**

Run:

```bash
swift test --filter ThreadIdentifierCompatibilityTests
```

Expected: failure on missing `Thread`, `threadID`, `ThreadPersistenceProtocol`, and
`WorkspaceURI.threadWorkspace` declarations.

- [ ] **Step 3: Implement the canonical model and protocol**

Rename the concrete model to `Thread` and use `Thread` throughout production code. Preserve the
existing `Codable` implementation exactly at the wire boundary:

```swift
extension Thread: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, isArchived, workingDirectory
        case attachedWorkspaceIDs = "attachedWorkspaceIds"
        case attachedAgentInstanceID = "attachedAgentInstanceId"
        case isPrivate
    }
}
```

Define `ThreadPersistenceProtocol` with `saveThread`, `fetchThread`, `fetchAllThreads`,
`deleteThread`, and `pruneThreads`. Keep a deprecated `TimelinePersistenceProtocol` containing
the old requirements. Add `LegacyTimelinePersistenceAdapter: ThreadPersistenceProtocol` that
forwards every canonical operation to an injected `any TimelinePersistenceProtocol`, and add
canonical configuration overloads that accept either protocol form.

Rename `InMemoryTimelinePersistence` to `InMemoryThreadPersistence`, then expose the old name as
a deprecated typealias. Add deprecated computed aliases for `timelineID`, `privateTimelineID`,
`timelineId`, `privateTimelineId`, `WorkspaceURI.timelineWorkspace`, and the old error-domain
symbol. For enum cases that cannot be typealiased, retain the old case with its historical
behavior/raw value, mark it deprecated, and normalize both old and new cases to the same error
code/message.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run:

```bash
swift test --filter ThreadAPICompatibilityTests
swift test --filter ThreadIdentifierCompatibilityTests
```

Expected: PASS with no production warnings other than compatibility declarations intentionally
marked deprecated.

- [ ] **Step 5: Commit the model and persistence slice**

```bash
git add Sources/PositronicKit/Models/Database/Timeline.swift \
  Sources/PositronicKit/Models/Database/ConversationMessage.swift \
  Sources/PositronicKit/Services/Database/TimelinePersistenceProtocol.swift \
  Sources/PositronicKit/Services/Storage/InMemoryTimelinePersistence.swift \
  Sources/PositronicKit/Services/Storage/InMemoryAgentInstanceStore.swift \
  Sources/PKShared/SharedTypes/AgentInstance.swift \
  Sources/PKShared/SharedTypes/TurnSnapshot.swift \
  Sources/PKShared/SharedTypes/WorkspaceURI.swift \
  Sources/PKShared/SharedTypes/WorkspaceReference.swift \
  Sources/PKShared/Utilities/PKError.swift \
  Sources/PositronicKit/Compatibility/TimelineAPICompatibility.swift \
  Sources/PKShared/Compatibility/TimelineAPICompatibility.swift \
  Tests/PKTestSupport
git commit -m "feat: add canonical thread model and persistence APIs"
```

---

### Task 3: Rename the manager, lifecycle, attachments, and runtime policy surface

**Files:**
- Modify: `Sources/PositronicKit/Services/Timeline/TimelineManager.swift`
- Modify: `Sources/PositronicKit/Services/Timeline/TimelineManager+Init.swift`
- Modify: `Sources/PositronicKit/Services/Timeline/TimelineManager+Lifecycle.swift`
- Modify: `Sources/PositronicKit/Services/Timeline/TimelineManager+Attachments.swift`
- Modify: `Sources/PositronicKit/Services/Timeline/TimelineManagerTypes.swift`
- Modify: `Sources/PositronicKit/Services/Timeline/RuntimeToolPolicyFactory.swift`
- Modify: `Sources/PositronicKit/Services/Timeline/TimelineArchiver.swift`
- Modify: `Sources/PositronicKit/Services/Timeline/TimelineTaskRegistry.swift`
- Modify: `Sources/PositronicKit/Services/Timeline/TimelineToolRegistry.swift`
- Test: `Tests/PositronicKitTests/TimelineManagerTests.swift`
- Test: `Tests/PositronicKitTests/TimelineLifecycleInvariantTests.swift`
- Test: `Tests/PositronicKitTests/TimelineLifecycleFaultInjectionTests.swift`
- Test: `Tests/PositronicKitTests/TimelineEvictionDeletionTests.swift`
- Test: `Tests/PositronicKitTests/Services/TimelineToolRegistryTests.swift`
- Test: `Tests/PositronicKitTests/Integration/TimelineArchiverTests.swift`

**Interfaces:**
- Consumes `Thread`, `ThreadPersistenceProtocol`, and the adapter from Task 2.
- Produces `ThreadManager`, `ThreadError`, `ThreadDeletionResult`, `ThreadArchiver`, `ThreadTaskRegistry`, `ThreadToolRegistry`, and canonical manager operations.

- [ ] **Step 1: Add failing manager tests for canonical names**

Convert the lifecycle assertions to use the desired signatures:

```swift
let manager = runtime.threadManager
let thread = try await manager.createThread(title: "Lifecycle")

#expect(manager.thread(id: thread.id)?.id == thread.id)
try await manager.updateThreadTitle(thread.id, title: "Renamed")
try await manager.attachWorkspace(workspaceID, to: thread.id)
let result = try await manager.deleteThreadPermanently(id: thread.id)
#expect(result.threadID == thread.id)
```

Add compile/runtime checks for `ThreadManager.RuntimeToolPolicy` using
`installThreadObservationTools` and `installThreadSendTool`, and for `ThreadManager.Stores.threadStore`.

- [ ] **Step 2: Run the manager tests and verify the canonical surface is absent**

Run:

```bash
swift test --filter ThreadManagerTests
```

Expected: compilation failure on `threadManager`, `createThread`, `thread(id:)`, and the renamed
result/policy members.

- [ ] **Step 3: Implement canonical manager declarations**

Rename the actor and nested public types. Rename lifecycle operations as follows:

| Existing declaration | Canonical declaration |
| --- | --- |
| `createTimeline` | `createThread` |
| `ensureTimelineExists` | `ensureThreadExists` |
| `hydrateTimeline` | `hydrateThread` |
| `updateTimelineTitle` | `updateThreadTitle` |
| `evictTimelineFromMemory` | `evictThreadFromMemory` |
| `deleteTimeline` | `deleteThread` |
| `deleteTimelinePermanently` | `deleteThreadPermanently` |
| `cleanupStaleTimelines` | `cleanupStaleThreads` |
| `timeline(id:)` | `thread(id:)` |
| `touchTimeline(id:)` | `touchThread(id:)` |
| `listTimelines()` | `listThreads()` |
| `TimelineError` | `ThreadError` |
| `TimelineDeletionResult` | `ThreadDeletionResult` |

Rename all public `timelineId`/`timelineID` parameters to `threadID`, and rename the store and
policy members to `threadStore`, `installThreadObservationTools`, and `installThreadSendTool`.
Add deprecated forwards with exact old labels. Keep private liveness dictionary names free to
change, but ensure deletion/cancellation behavior is byte-for-byte equivalent.

Expose `@available(*, deprecated, renamed: ...)` aliases for `TimelineManager`, `TimelineError`,
`TimelineDeletionResult`, `TimelineArchiver`, `TimelineTaskRegistry`, and `TimelineToolRegistry`
in the PositronicKit compatibility file.

- [ ] **Step 4: Run the manager and lifecycle tests**

Run:

```bash
swift test --filter ThreadManagerTests
swift test --filter TimelineLifecycleInvariantTests
swift test --filter TimelineLifecycleFaultInjectionTests
swift test --filter TimelineEvictionDeletionTests
swift test --filter TimelineToolRegistryTests
swift test --filter TimelineArchiverTests
```

Expected: PASS; the old-named tests may remain temporarily as deprecated compatibility coverage,
but their implementation should call the canonical manager internally.

- [ ] **Step 5: Commit the manager slice**

```bash
git add Sources/PositronicKit/Services/Timeline
git add Tests/PositronicKitTests/TimelineManagerTests.swift \
  Tests/PositronicKitTests/TimelineLifecycleInvariantTests.swift \
  Tests/PositronicKitTests/TimelineLifecycleFaultInjectionTests.swift \
  Tests/PositronicKitTests/TimelineEvictionDeletionTests.swift \
  Tests/PositronicKitTests/Services/TimelineToolRegistryTests.swift \
  Tests/PositronicKitTests/Integration/TimelineArchiverTests.swift
git commit -m "feat: rename timeline manager APIs to threads"
```

---

### Task 4: Rename the facade, drivers, requests, agent runtime, and cross-cutting IDs

**Files:**
- Modify: `Sources/PositronicKit/PositronicKit.swift`
- Modify: `Sources/PositronicKit/PositronicKit+Configuration.swift`
- Modify: `Sources/PositronicKit/PositronicKit+Dependencies.swift`
- Modify: `Sources/PositronicKit/TimelineDriver.swift`
- Modify: `Sources/PositronicKit/AgenticRuntime.swift`
- Modify: `Sources/PositronicKit/ChatRunRequest.swift`
- Modify: `Sources/PositronicKit/Protocols/PromptSectionProviding.swift`
- Modify: `Sources/PositronicKit/Protocols/ChatTurnPlugin.swift`
- Modify: `Sources/PositronicKit/Protocols/PromptObserving.swift`
- Modify: `Sources/PositronicKit/Services/Chat/ChatEngine.swift`
- Modify: `Sources/PositronicKit/Services/Chat/ChatEngine+TurnLoop.swift`
- Modify: `Sources/PositronicKit/Services/Chat/ChatEngine+TurnPreparation.swift`
- Modify: `Sources/PositronicKit/Services/Chat/ChatTurnContext.swift`
- Test: `Tests/PositronicKitTests/TimelineDriverTests.swift`
- Test: `Tests/PositronicKitTests/FacadeOneShotTests.swift`
- Test: `Tests/PositronicKitTests/FacadeRunValidationTests.swift`
- Test: `Tests/PositronicKitTests/PromptObservingTests.swift`
- Test: `Tests/PositronicKitTests/NoOpEmbeddingServiceAndChatRunRequestTests.swift`

**Interfaces:**
- Consumes `ThreadManager` from Task 3.
- Produces `PositronicKit.threadManager`, `PositronicKit.openThread(_:) -> ThreadDriver`,
  `ThreadDriver.threadID`, `AgenticRuntime.threadID`, `ChatRunRequest.threadID`, and canonical
  `threadID` initializers/properties across prompt and turn contexts.

- [ ] **Step 1: Add failing facade/driver tests**

Extend the compatibility suite with these compile/runtime assertions:

```swift
let thread = try await kit.threadManager.createThread()
let driver: ThreadDriver = kit.openThread(thread.id)
let runtime = kit.agenticRuntime(threadID: thread.id, agentInstanceID: nil)
let request = ChatRunRequest(threadID: thread.id, message: "hello")

#expect(driver.threadID == thread.id)
#expect(runtime.threadID == thread.id)
#expect(request.threadID == thread.id)
```

Add deprecated forwards for `timelineManager`, `openTimeline`, `TimelineDriver`, the old
`timelineID` initializers, and old `timelineId` properties. Keep one-shot APIs explicitly
thread-free in their documentation and behavior.

- [ ] **Step 2: Run the facade tests and verify the expected missing-symbol failures**

Run:

```bash
swift test --filter ThreadAPICompatibilityTests
swift test --filter TimelineDriverTests
```

Expected: failure until the canonical facade members and driver exist.

- [ ] **Step 3: Implement canonical facade and request APIs**

Make the facade’s stored canonical members primary:

```swift
public let threadManager: ThreadManager

public func openThread(_ threadID: UUID) -> ThreadDriver {
    ThreadDriver(threadID: threadID, kit: self)
}

public func agenticRuntime(
    threadID: UUID,
    agentInstanceID: UUID? = nil
) -> AgenticRuntime {
    AgenticRuntime(threadID: threadID, agentInstanceID: agentInstanceID, kit: self)
}
```

Retain deprecated `timelineManager`, `openTimeline`, `agenticRuntime(timelineID:...)`, old
initializers, and old properties as forwards. Update internal ChatEngine calls to canonical names
so production does not depend on deprecated APIs.

- [ ] **Step 4: Run focused facade and request tests**

Run:

```bash
swift test --filter ThreadAPICompatibilityTests
swift test --filter TimelineDriverTests
swift test --filter FacadeOneShotTests
swift test --filter FacadeRunValidationTests
swift test --filter PromptObservingTests
```

Expected: PASS with identical stream, cancellation, hydration, and validation behavior.

- [ ] **Step 5: Commit the facade slice**

```bash
git add Sources/PositronicKit/PositronicKit.swift \
  Sources/PositronicKit/PositronicKit+Configuration.swift \
  Sources/PositronicKit/PositronicKit+Dependencies.swift \
  Sources/PositronicKit/TimelineDriver.swift \
  Sources/PositronicKit/AgenticRuntime.swift \
  Sources/PositronicKit/ChatRunRequest.swift \
  Sources/PositronicKit/Protocols \
  Sources/PositronicKit/Services/Chat
git add Tests/PositronicKitTests/TimelineDriverTests.swift \
  Tests/PositronicKitTests/FacadeOneShotTests.swift \
  Tests/PositronicKitTests/FacadeRunValidationTests.swift \
  Tests/PositronicKitTests/PromptObservingTests.swift \
  Tests/PositronicKitTests/NoOpEmbeddingServiceAndChatRunRequestTests.swift
git commit -m "feat: expose thread-first runtime facade"
```

---

### Task 5: Rename agent, workspace, prompt, tool, error, and observable surfaces

**Files:**
- Modify: `Sources/PositronicKit/Services/Agents/AgentInstanceManager.swift`
- Modify: `Sources/PositronicKit/Services/Agents/AgentInstanceManagerProtocol.swift`
- Modify: `Sources/PositronicKit/Services/Agents/AgentInstanceError.swift`
- Modify: `Sources/PositronicKit/Services/Prompting/TimelinePromptHistory.swift`
- Modify: `Sources/PositronicKit/Services/Prompting/TimelinePromptHistoryTypes.swift`
- Modify: `Sources/PositronicKit/Services/Prompting/TimelinePromptJournals.swift`
- Modify: `Sources/PositronicKit/Services/Prompting/Sections/PromptSections.swift`
- Modify: `Sources/PositronicKit/Services/Prompting/PromptAssembler.swift`
- Modify: `Sources/PositronicKit/Services/Prompting/DefaultInstructions.swift`
- Modify: `Sources/PositronicKit/Services/Tools/Timeline/TimelineListTool.swift`
- Modify: `Sources/PositronicKit/Services/Tools/Timeline/TimelinePeekTool.swift`
- Modify: `Sources/PositronicKit/Services/Tools/Timeline/TimelineSendTool.swift`
- Modify: `Sources/PositronicKit/Services/Tools/ToolRouter.swift`
- Modify: `Sources/PositronicKit/Services/Workspace/WorkspaceResolverFactory.swift`
- Modify: `Sources/PositronicKit/Models/Workspace/WorkspaceProfile.swift`
- Modify: `Sources/PKShared/Tools/ToolError.swift`
- Modify: `Sources/PKObservable/TimelineController.swift`
- Create: `Sources/PKObservable/Compatibility/TimelineAPICompatibility.swift`
- Test: `Tests/PKObservableTests/TimelineControllerTests.swift`
- Test: `Tests/PositronicKitTests/AgentInstanceManagerTests.swift`
- Test: `Tests/PositronicKitTests/Services/PromptSectionsTests.swift`
- Test: `Tests/PositronicKitTests/TimelineObservationToolsTests.swift`
- Test: `Tests/PositronicKitTests/TimelineSendToolTests.swift`
- Test: `Tests/PositronicKitTests/Services/RuntimeToolPolicyFactoryTests.swift`

**Interfaces:**
- Consumes canonical manager/driver IDs from Tasks 3–4.
- Produces `ThreadController`, `ThreadPromptHistory`, `ThreadPromptJournals`, `ThreadPromptHistoryError`, `ThreadContext`, `ThreadListTool`, `ThreadPeekTool`, `ThreadSendTool`, `threads(attachedTo:)`, and thread-named agent error cases.

- [ ] **Step 1: Add failing tests for the remaining public names**

Use the existing behavior tests with canonical calls:

```swift
let controller = ThreadController(driver)
let context = ThreadContext(thread)
let tools = ThreadListTool(threadStore: runtime.persistence)
let attached = try await runtime.agentInstanceManager.threads(attachedTo: agent.id)

#expect(controller.driver.threadID == thread.id)
#expect(context.thread.id == thread.id)
#expect(attached.map(\.id).contains(thread.id))
```

For error cases, assert that `ThreadError.threadNotFound`,
`AgentInstanceError.threadAgentMismatch`, and
`ToolError.attachedToolsDisallowedOnPrivateThread` keep the existing codes/messages. Retain old
cases as deprecated compatibility cases and assert they normalize to the same values.

- [ ] **Step 2: Run the focused tests and verify missing canonical names**

Run:

```bash
swift test --filter ThreadControllerCompatibilityTests
swift test --filter TimelineObservationToolsTests
swift test --filter TimelineSendToolTests
```

Expected: compilation failure for the new controller, context, tools, and agent query names.

- [ ] **Step 3: Implement canonical names and compatibility aliases**

Rename the public types and add deprecated aliases for all type names. Rename agent APIs:

- `timelines(attachedTo:)` → `threads(attachedTo:)`.
- `getTimelines(attachedTo:)` → `getThreads(attachedTo:)`.
- `privateTimelineID` → `privateThreadID`.
- `timelineNotFound`, `timelineAgentMismatch`, `hasAttachedTimelines`,
  `cannotAttachToPrivateTimeline`, and `cannotDetachFromOwnPrivateTimeline` → thread cases,
  with old cases retained and deprecated.

Rename prompt and tool types/properties while keeping external names untouched:

- `TimelinePromptHistory`/`TimelinePromptJournals`/`TimelinePromptHistoryError` → thread names.
- `TimelineContext.timeline`/`timelineTitle` → `ThreadContext.thread`/`threadTitle`.
- `TimelineListTool`/`TimelinePeekTool`/`TimelineSendTool` → thread names.
- `TimelineController` → `ThreadController`.

The new tools must continue to publish `timeline_list`, `timeline_peek`, and `timeline_send`.
The new controller must still wrap `ThreadDriver` and preserve streaming state behavior.

- [ ] **Step 4: Run focused observable, agent, prompt, and tool tests**

Run:

```bash
swift test --filter ThreadControllerCompatibilityTests
swift test --filter TimelineControllerTests
swift test --filter AgentInstanceManagerTests
swift test --filter PromptSectionsTests
swift test --filter TimelineObservationToolsTests
swift test --filter TimelineSendToolTests
swift test --filter RuntimeToolPolicyFactoryTests
```

Expected: PASS with unchanged tool routing, workspace attachment, prompt composition, and
observable streaming behavior.

- [ ] **Step 5: Commit the remaining public surface**

```bash
git add Sources/PositronicKit/Services/Agents \
  Sources/PositronicKit/Services/Prompting \
  Sources/PositronicKit/Services/Tools \
  Sources/PositronicKit/Services/Workspace \
  Sources/PositronicKit/Models/Workspace/WorkspaceProfile.swift \
  Sources/PKShared/Tools/ToolError.swift \
  Sources/PKObservable
git add Tests/PKObservableTests/TimelineControllerTests.swift \
  Tests/PositronicKitTests/AgentInstanceManagerTests.swift \
  Tests/PositronicKitTests/Services/PromptSectionsTests.swift \
  Tests/PositronicKitTests/TimelineObservationToolsTests.swift \
  Tests/PositronicKitTests/TimelineSendToolTests.swift \
  Tests/PositronicKitTests/Services/RuntimeToolPolicyFactoryTests.swift
git commit -m "feat: rename thread tools and observable APIs"
```

---

### Task 6: Migrate examples, documentation, support fixtures, and existing tests

**Files:**
- Modify: `Sources/PositronicKitExamples/PositronicKitUsageExamples.swift`
- Modify: `Sources/PositronicKitExamples/main.swift`
- Modify: `Sources/PositronicKit/PositronicKit.docc/PositronicKit.md`
- Modify: `Sources/PositronicKit/PositronicKit.docc/PersistenceLayer.md`
- Modify: `README.md`
- Modify: `docs/Architecture.md`
- Modify: `docs/Setup.md`
- Modify: `docs/Usage.md`
- Modify: `docs/PKPromptComposition.md`
- Modify: `docs/index.html`
- Modify: `Tests/PKTestSupport/FailingStores.swift`
- Modify: `Tests/PKTestSupport/MockMessageStore.swift`
- Modify: `Tests/PKTestSupport/MockPersistenceService.swift`
- Modify: `Tests/PKTestSupport/MockTimelinePersistence.swift`
- Modify: `Tests/PKTestSupport/TestFixtures.swift`
- Modify: `Tests/PKTestSupport/TestRuntime.swift`
- Modify: `Tests/PKObservableTests/TimelineControllerTests.swift`
- Modify: `Tests/PKSharedTests/ChatEventTests.swift`
- Modify: `Tests/PKSharedTests/CoreAPIClarityTests.swift`
- Modify: `Tests/PKSharedTests/ErrorCausalityTests.swift`
- Modify: `Tests/PKSharedTests/SharedModelCoverageTests.swift`
- Modify: `Tests/PKSharedTests/Tools/ToolErrorSurfacesTests.swift`
- Modify: `Tests/PKSharedTests/WorkspaceURITests.swift`
- Modify: `Tests/PKTestSupportTests/BatchFailingMessageStoreTests.swift`
- Modify: `Tests/PKTestSupportTests/MockPersistenceConcurrencyTests.swift`
- Modify: `Tests/PKTestSupportTests/MockPersistenceServiceTests.swift`
- Modify: `Tests/PKUtilitiesTests/Utilities/ANSIColorsLoggingTests.swift`
- Modify: `Tests/PositronicKitTests/AgentInstanceManagerTests.swift`
- Modify: `Tests/PositronicKitTests/ChatEngineFailurePersistenceTests.swift`
- Modify: `Tests/PositronicKitTests/ChatEnginePipelineTests.swift`
- Modify: `Tests/PositronicKitTests/ChatEngineTerminalEventTests.swift`
- Modify: `Tests/PositronicKitTests/ChatEngineTerminalInvariantTests.swift`
- Modify: `Tests/PositronicKitTests/ChatEngineTests.swift`
- Modify: `Tests/PositronicKitTests/CoreAPIClarityTests.swift`
- Modify: `Tests/PositronicKitTests/DefaultWorkspaceCatalogTests.swift`
- Modify: `Tests/PositronicKitTests/DependencySafetyTests.swift`
- Modify: `Tests/PositronicKitTests/DurabilityConfigurationTests.swift`
- Modify: `Tests/PositronicKitTests/FacadeOneShotTests.swift`
- Modify: `Tests/PositronicKitTests/FacadeRunValidationTests.swift`
- Modify: `Tests/PositronicKitTests/GenerationParametersTests.swift`
- Modify: `Tests/PositronicKitTests/HydrationFailurePropagationTests.swift`
- Modify: `Tests/PositronicKitTests/Integration/TimelineArchiverTests.swift`
- Modify: `Tests/PositronicKitTests/InternalStories/CustomPipelineStageInternalStoriesTests.swift`
- Modify: `Tests/PositronicKitTests/InternalStories/IntroductoryRuntimeInternalStoriesTests.swift`
- Modify: `Tests/PositronicKitTests/LoggingRedactionTests.swift`
- Modify: `Tests/PositronicKitTests/MemoryStoreWiringTests.swift`
- Modify: `Tests/PositronicKitTests/Models/Database/ConversationMessageTests.swift`
- Modify: `Tests/PositronicKitTests/Models/Database/TimelineTests.swift`
- Modify: `Tests/PositronicKitTests/NoOpEmbeddingServiceAndChatRunRequestTests.swift`
- Modify: `Tests/PositronicKitTests/PositronicKitErrorContractTests.swift`
- Modify: `Tests/PositronicKitTests/PromptObservingTests.swift`
- Modify: `Tests/PositronicKitTests/PromptSnapshotBuilderTests.swift`
- Modify: `Tests/PositronicKitTests/Services/AgentInstanceStoreContractTests.swift`
- Modify: `Tests/PositronicKitTests/Services/ChatEngineStageTests.swift`
- Modify: `Tests/PositronicKitTests/Services/GroupedInitToolApprovalPolicyWiringTests.swift`
- Modify: `Tests/PositronicKitTests/Services/InMemoryStoresContractTests.swift`
- Modify: `Tests/PositronicKitTests/Services/LLMStreamingStageReasoningTests.swift`
- Modify: `Tests/PositronicKitTests/Services/PersistenceProtocolTests.swift`
- Modify: `Tests/PositronicKitTests/Services/PromptSectionsTests.swift`
- Modify: `Tests/PositronicKitTests/Services/PruneDryRunTests.swift`
- Modify: `Tests/PositronicKitTests/Services/RuntimeToolPolicyFactoryTests.swift`
- Modify: `Tests/PositronicKitTests/Services/TimelineToolRegistryTests.swift`
- Modify: `Tests/PositronicKitTests/Services/ToolApprovalPolicyFilesystemToolsTests.swift`
- Modify: `Tests/PositronicKitTests/Services/ToolRouterTests.swift`
- Modify: `Tests/PositronicKitTests/Services/ToolTimeoutEnforcerTests.swift`
- Modify: `Tests/PositronicKitTests/Services/Workspace/DefaultWorkspaceResolverTests.swift`
- Modify: `Tests/PositronicKitTests/Services/Workspace/TimelineManagerWorkspaceResolverContractTests.swift`
- Modify: `Tests/PositronicKitTests/SessionManagerConcurrencyTests.swift`
- Modify: `Tests/PositronicKitTests/SidecarStreamingStageTests.swift`
- Modify: `Tests/PositronicKitTests/SidecarTurnIntegrationTests.swift`
- Modify: `Tests/PositronicKitTests/StoreErrorClassificationTests.swift`
- Modify: `Tests/PositronicKitTests/Stories/Extensions/ExtensionStoriesTests.swift`
- Modify: `Tests/PositronicKitTests/Stories/Runtime/PublicRuntimeStoriesTests.swift`
- Modify: `Tests/PositronicKitTests/Stories/Setup/RuntimeSetupStoriesTests.swift`
- Modify: `Tests/PositronicKitTests/Stories/StoryCoverageIndex.swift`
- Modify: `Tests/PositronicKitTests/StructuredOutputRunTests.swift`
- Modify: `Tests/PositronicKitTests/TimelineCancellationTests.swift`
- Modify: `Tests/PositronicKitTests/TimelineDriverTests.swift`
- Modify: `Tests/PositronicKitTests/TimelineEvictionDeletionTests.swift`
- Modify: `Tests/PositronicKitTests/TimelineLifecycleFaultInjectionTests.swift`
- Modify: `Tests/PositronicKitTests/TimelineLifecycleInvariantTests.swift`
- Modify: `Tests/PositronicKitTests/TimelineManagerTests.swift`
- Modify: `Tests/PositronicKitTests/TimelineObservationToolsTests.swift`
- Modify: `Tests/PositronicKitTests/TimelinePromptHistoryTests.swift`
- Modify: `Tests/PositronicKitTests/TimelineSendToolTests.swift`
- Modify: `Tests/PositronicKitTests/ToolCallRegressionTests.swift`
- Modify: `Tests/PositronicKitTests/ToolRouterConcurrencyTests.swift`
- Modify: `Tests/PositronicKitTests/TurnDegradationPolicyTests.swift`
- Modify: `Tests/PositronicKitTests/TurnPreparationIdempotencyTests.swift`
- Modify: `Tests/PositronicKitTests/WorkspaceAttachmentTests.swift`
- Modify: `Tests/PositronicKitTests/WorkspaceProfileLifecycleTests.swift`

**Interfaces:**
- Consumes every canonical production symbol from Tasks 2–5.
- Produces a canonical-only first-party codebase, with old names appearing only in compatibility tests, compatibility declarations, historical storage/wire assertions, and the changelog.

- [ ] **Step 1: Add a canonical example smoke test**

Update the executable example to compile and run this thread-first flow:

```swift
let thread = try await kit.threadManager.createThread(title: "Docs agent")
let driver = kit.openThread(thread.id)
for try await event in try await driver.send("Hello") {
    print(event)
}
```

- [ ] **Step 2: Run the example and documentation checks before migration**

Run:

```bash
swift run PositronicKitExamples --help
```

Expected: the existing example still references old names, demonstrating the migration work
remaining in this task.

- [ ] **Step 3: Migrate first-party call sites**

Use the code graph to identify definitions and callers, then update every first-party reference
to canonical names. Do not change string literals that are persistence keys, raw enum values,
tool call names, or historical compatibility assertions. Update prose to “thread” except when it
describes the v3 compatibility API or historical data.

Update `TestRuntime` to expose `threadManager`, `threadPersistence`, and `positronicKit` as its
canonical properties. Keep `timelineManager`, `timelinePersistence`, and `buildCore()` only when
they are explicit compatibility tests; mark those forwards deprecated.

Rename test suite/type names and test method names from `Timeline…`/`timeline…` to
`Thread…`/`thread…` as part of this migration, while leaving file paths unchanged unless a file
move is needed by the target’s source layout.

- [ ] **Step 4: Run the canonical examples and representative stories**

Run:

```bash
swift run PositronicKitExamples
swift test --filter PublicRuntimeStoriesTests
swift test --filter RuntimeSetupStoriesTests
swift test --filter PersistenceProtocolTests
swift test --filter InMemoryStoresContractTests
```

Expected: PASS, with examples and public stories using only thread terminology.

- [ ] **Step 5: Commit the first-party migration**

```bash
git add Sources/PositronicKitExamples Sources/PositronicKit/PositronicKit.docc \
  README.md docs Tests/PKTestSupport Tests
git commit -m "refactor: migrate first-party callers to thread APIs"
```

---

### Task 7: Document the deprecation and validate the complete compatibility boundary

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `Sources/PositronicKit/Compatibility/TimelineAPICompatibility.swift`
- Modify: `Sources/PKShared/Compatibility/TimelineAPICompatibility.swift`
- Modify: `Sources/PKObservable/Compatibility/TimelineAPICompatibility.swift`
- Test: `Tests/PositronicKitTests/ThreadAPICompatibilityTests.swift`
- Test: `Tests/PKSharedTests/ThreadIdentifierCompatibilityTests.swift`
- Test: `Tests/PKObservableTests/ThreadControllerCompatibilityTests.swift`

**Interfaces:**
- Consumes the fully migrated canonical API.
- Produces the final documented v3 compatibility surface and a verified v4 removal checklist.

- [ ] **Step 1: Add the changelog entry**

Under `## [Unreleased]`, add:

```markdown
### Deprecated

- **Timeline-to-Thread API migration:** `Thread` is now the canonical terminology across the
  runtime, persistence, agent, prompt, tool, driver, and observable APIs. The existing `Timeline`
  types, methods, properties, identifiers, and persistence conformer surface remain available as
  deprecated compatibility shims and will be removed in v4. Persisted keys, database schema, error
  codes/domains, and external tool call identifiers are unchanged.
```

- [ ] **Step 2: Verify every old public name has a diagnostic and a canonical replacement**

Search the compatibility declarations and inspect each result. The following categories must be
covered: typealiases, facade properties/methods, manager lifecycle methods, persistence methods,
driver/controller types, `timelineID`/`timelineId` properties and initializers, agent/workspace
queries, prompt/tool types, and enum cases. A compatibility symbol without `@available` is a
failure unless it is a historical raw value or serialized key.

Run:

```bash
rg -n 'Timeline|timeline' Sources/PositronicKit/Compatibility \
  Sources/PKShared/Compatibility Sources/PKObservable/Compatibility
```

Expected: every API declaration in these files carries a deprecation annotation with a direct
thread replacement or the shared v4 message.

- [ ] **Step 3: Verify the old and new API compile contracts**

Run:

```bash
swift test --filter ThreadAPICompatibilityTests
swift test --filter ThreadIdentifierCompatibilityTests
swift test --filter ThreadControllerCompatibilityTests
swift test --filter CoreAPIClarityTests
swift test --filter SharedModelCoverageTests
```

Expected: PASS. Compatibility helpers are deprecated contexts so expected legacy usage does not
create unrelated warning noise.

- [ ] **Step 4: Verify wire/storage stability**

Run:

```bash
swift test --filter ThreadTests
swift test --filter ConversationMessageTests
swift test --filter WorkspaceURITests
swift test --filter ChatEventTests
swift test --filter PersistenceProtocolTests
```

Expected: PASS with historical JSON keys, raw values, error codes, and tool call names intact.

- [ ] **Step 5: Commit the deprecation documentation**

```bash
git add CHANGELOG.md Sources/PositronicKit/Compatibility \
  Sources/PKShared/Compatibility Sources/PKObservable/Compatibility \
  Tests/PositronicKitTests/ThreadAPICompatibilityTests.swift \
  Tests/PKSharedTests/ThreadIdentifierCompatibilityTests.swift \
  Tests/PKObservableTests/ThreadControllerCompatibilityTests.swift
git commit -m "docs: deprecate timeline APIs for v4"
```

---

### Task 8: Run the complete repository verification gate

**Files:**
- Inspect: all changed files and `git diff`
- Verify: `Package.swift`, generated products, examples, DocC, and all test targets

**Interfaces:**
- Consumes all implementation and compatibility commits from Tasks 1–7.
- Produces fresh verification evidence for the final handoff.

- [ ] **Step 1: Check the diff and generated API surface**

Run:

```bash
git diff --check HEAD~7..HEAD
git status --short
rg -n 'public (struct|class|actor|enum|protocol).*Timeline|public .*timelineManager|public .*createTimeline|public .*openTimeline' Sources --glob '*.swift'
```

Expected: only explicitly deprecated compatibility declarations and historical wire/storage
symbols match; canonical production declarations use `Thread`/`thread` names.

- [ ] **Step 2: Run the full native macOS gate**

Run:

```bash
make verify
```

Expected: exit code 0, documentation/product/example/linkage checks pass, and all test targets
pass. If a compatibility warning appears outside the intentionally deprecated contexts, fix the
declaration or migrate that first-party call site before proceeding.

- [ ] **Step 3: Inspect final status and commit summary**

Run:

```bash
git status --short --branch
git log --oneline -9
```

Expected: only intentional implementation commits are present, no generated artifacts are
untracked, and the branch contains the approved design commit followed by the implementation
commits.
