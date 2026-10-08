# PositronicKit SwiftUI Guide

This guide documents the unreleased Next `PKObservable` story. `TimelineController` is a
`@Observable` `@MainActor` controller that mirrors one `TimelineHandle` into SwiftUI state:
completed `messages`, in-flight `streamingText`/`isStreaming`, and the durable terminal truth of
the last send (`lastTurnID`, `lastOutcome`, `lastError`).

Keep the `PKRuntime` in an app-owned service. The runtime is a long-lived value; the controller
is per-Timeline view state bound to one handle.

## Hold the runtime in an app-owned service

Create the runtime once and hand handles to views. The service below is illustrative; wire your
own provider and stores through `PKRuntime` initializers documented in `docs/Setup.md`.

```swift main-actor
let timeline = try await kit.timelines.create(title: "Chat", attaching: agent.id)
let controller = TimelineController(timeline)
try await controller.send("Hi")
```

The managed initializer admits managed Turns through `TimelineHandle.startTurn(_:)`. Every send
supersedes the in-flight one: the prior task is cancelled, the driver's generation is cancelled,
and the new send starts fresh.

## Bind a detached Timeline directly

A detached Timeline takes the direct path with an explicit `DirectTurnContext`. The initializer
selects the admission path; `send(_:)` behaves identically on both.

```swift main-actor
let scratchpad = try await kit.timelines.create(title: "Scratchpad")
let direct = TimelineController(
    scratchpad,
    context: DirectTurnContext(systemInstructions: "You are a helpful assistant.")
)
try await direct.send("Summarize this timeline.")
```

## Join the durable outcome and cancel from the UI

After the event stream drains, the controller records the same durable outcome every joiner sees
via `TurnHandle.outcome()`. Cancellation clears streaming state and surfaces `CancellationError`;
runtime and durability failures surface `TimelineControllerError` and are also kept on `lastError`.

```swift main-actor
let observed = try await kit.timelines.create(title: "Observed", attaching: agent.id)
let watched = TimelineController(observed)
try await watched.send("Hi")
let outcome = watched.lastOutcome
await watched.cancel()
```

## Run auxiliary work on a fork

`timelines.fork(from:context:)` clones a Timeline's session into a detached, ephemeral
`TimelineFork` with read-only tool access. Bind it with the fork initializer; the fork's runtime
is released with the fork handle.

```swift main-actor
let source = try await kit.timelines.create(title: "Source", attaching: agent.id)
let fork = try await kit.timelines.fork(
    from: source.timelineID,
    context: DirectTurnContext(systemInstructions: "You audit the previous answer.")
)
let forked = TimelineController(fork)
try await forked.send("Audit the last answer for contradictions.")
```

## Sketch of a SwiftUI view (illustrative)

`TimelineController` is `@Observable`, so a view holds it with `@State` and reads `messages`,
`streamingText`, and `isStreaming` directly. `SwiftUI` is Apple-only and is not imported by the
snippet gate, so this sketch is intentionally parse-only:

```swift skip
import SwiftUI

struct TimelineView: View {
    @State private var controller: TimelineController

    init(controller: TimelineController) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        List(controller.messages, id: \.id) { message in
            Text(message.content)
        }
        .overlay(alignment: .bottom) {
            if controller.isStreaming {
                Text(controller.streamingText)
            }
        }
        .task {
            try? await controller.send("Hi")
        }
    }
}
```
