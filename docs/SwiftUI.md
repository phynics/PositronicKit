# PositronicKit SwiftUI Guide

This guide documents the 7.0 `PKObservable` story. `TimelineController` is a
`@Observable` `@MainActor` controller that mirrors one `TimelineHandle` into SwiftUI state:
completed `messages`, in-flight `streamingText`/`isStreaming`, the durable terminal truth of
the last send (`lastTurnID`, `lastOutcome`, `lastError`), the per-round `promptCacheReports`,
and any `quarantine` blocking the Timeline.

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

## Show prompt-cache diagnostics

Every model round emits a `PromptCacheReport` after its usage arrives. The controller mirrors
them on `promptCacheReports`, oldest first, and clears the list when the next send starts. Each
report carries the expected reusable prefix, the provider's cache reads and writes, the
breakpoints sent, and the reasons a prefix reset. A view can show cache hits and prefix resets
without reading the Turn's durable correlations.

```swift main-actor
let cached = try await kit.timelines.create(title: "Cached", attaching: agent.id)
let cachedController = TimelineController(cached)
try await cachedController.send("Hi")
if let latest = cachedController.promptCacheReports.last {
    // Render the provider's cache reads and the expected reusable prefix.
    print(latest.expectedReusableTokens, latest.reportedCachedTokens ?? 0)
}
```

## Recover a quarantined conversation

A Turn that an interruption cannot safely retry is quarantined: its Timeline rejects new sends
until an operator confirms the side effect was reconciled. The controller mirrors that marker in
`quarantine`, refreshed after every send and by `refreshQuarantine()`.

```swift main-actor
let watchedTimeline = try await kit.timelines.create(title: "Watched", attaching: agent.id)
let watched = TimelineController(watchedTimeline)
try? await watched.send("Hi")
if watched.quarantine != nil {
    // Explain `watched.quarantine?.reason`, then let the operator confirm recovery:
    try await watched.release(
        confirmation: QuarantineReleaseConfirmation(
            phrase: QuarantineReleaseConfirmation.requiredPhrase
        )
    )
}
```

## Streaming deltas and observation granularity

`streamingText` changes once per streamed token, so a SwiftUI view bound to the controller
re-renders as text arrives and always sees the accumulated text. A non-SwiftUI consumer that
observes the controller through the `Observation` sequence gets the latest value, not a lossless
log of every token: writes with no suspension between them coalesce, and even one `Task.yield()`
per write does not guarantee one observed element per write (#197, measured against the 7.0 floor
toolchain). The fine-grained continuous-observation API is `anyAppleOS 27` and `Observations` is
`anyAppleOS 26`, both above the package's macOS 15 / iOS 18 floor, so `PKObservable` does not offer
either as the default path. A consumer that needs every token consumes `TurnEvent`s from
`TimelineHandle` directly, which is what the controller itself does.

## Run auxiliary work on a fork

`timelines.fork(from:title:)` returns an ordinary detached `TimelineHandle` for an ephemeral
Timeline in the same runtime. Bind it with the direct-path controller initializer; the runtime
deletes the ephemeral Timeline when the last handle is released.

```swift main-actor
let source = try await kit.timelines.create(title: "Source", attaching: agent.id)
let fork = try await kit.timelines.fork(from: source.timelineID)
let forked = TimelineController(
    fork,
    context: DirectTurnContext(systemInstructions: "You audit the previous answer.")
)
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
