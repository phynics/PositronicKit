# Sidecar Directives Mechanism (PositronicKit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PK-side mechanism for piggy-backed requests: declare `SidecarDirective`s on a chat turn, compose one structured-output schema (`response` first + one field per directive), stream the `response` field to consumers as normal `.generation` deltas via incremental JSON parsing (PartialJSON), and emit directive values through new `ChatEvent` cases.

**Architecture:** New shared types in `PKShared` (`SidecarDirective`, `SidecarDelta`, `SidecarResult`, `ChatEvent` cases); composition + extraction in the `PositronicKit` target (`SidecarSchemaComposer`, `SidecarStreamExtractor` wired inside `LLMStreamingStage`); `ChatEngine.execute(sidecars:)` entry point. Spec: `workflow/Yakamoz/specs/2026-07-03-piggybacked-requests-design.md`.

**Tech Stack:** Swift 6, SwiftPM, swift-json-schema 0.11.2, [PartialJSON](https://github.com/itruf/PartialJSON) (new dep), Swift Testing for new test files, `PKTestSupport` mocks.

**Scope notes / deviations from spec (with rationale):**
- Prompt instructions inject via `systemInstructions` composition in `prepareSession`, not `PromptSectionProviding`: directives are per-turn `executeTurn` parameters, while section providers are registered per-session on `TimelineManager` — using them would force consumers to register directive state twice. Composition stays outside `ChatEngine` branching (a pure `SidecarSchemaComposer.instructionBlock` function).
- Sidecar turns go through the existing `chatStream(structuredOutput:)` path (`LLMServiceProtocol+StructuredOutput.swift:29-59`), which already handles all four providers including the synthetic-tool fallback. The `chatStreamWithContext`/`apply` divergence is ticket SDC-3, not this plan.
- The Yakamoz consumer (directives, routing, inspector) is a **separate plan** written after this lands on remote `main` (WS-1 push+resync).
- New `ChatEvent` cases are additive; PK-internal exhaustive switches are updated here. Downstream (Monad/Shuttle sibling-path) build verification is the final task.

**Verification gate:** `cd PositronicKit && make verify` (plus `swift build`/`swift test` per task).

---

### Task 1: Add PartialJSON dependency

**Files:**
- Modify: `PositronicKit/Package.swift:26-32` (workspace `dependencies` array) and the `PositronicKit` target block (`:49-61`)

- [ ] **Step 1: Add the package dependency**

In `Package.swift` `dependencies:` (after the swift-crypto line, `:31`):

```swift
.package(url: "https://github.com/itruf/PartialJSON.git", exact: "0.0.2"),
```

(`exact` matches the repo convention used for OpenAI/swift-json-schema/swift-crypto pins.)

In the `PositronicKit` target's `dependencies:` (`:51-58`), add:

```swift
.product(name: "PartialJSON", package: "PartialJSON"),
```

Do **not** add it to `PKShared` — shared types don't parse; only the extraction stage does.

- [ ] **Step 2: Resolve and build**

Run: `cd /Volumes/Development/monad-project/PositronicKit && swift build`
Expected: resolves PartialJSON 0.0.2, builds clean.

- [ ] **Step 3: Smoke-check the API assumption**

Add a temporary snippet nowhere — instead verify via a quick REPL-style test in Task 5's test file later. (PartialJSON's documented API: `try PartialJSON.parse(_ s: String, options: PartialJSONOptions)` returning `Any`; options include `.string` for partial strings, sets `.atomic`/`.collections`/`.all`. If the real API differs, adapt `SidecarStreamExtractor`'s single call site — it is the only place PartialJSON is imported.)

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat: add PartialJSON dependency for sidecar incremental parsing"
```

---

### Task 2: `SidecarDirective` shared type

**Files:**
- Create: `PositronicKit/Sources/PKShared/SharedTypes/SidecarDirective.swift`
- Test: `PositronicKit/Tests/PKSharedTests/SidecarDirectiveTests.swift` (Swift Testing)

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import struct JSONSchema.Schema
@testable import PKShared

@Suite struct SidecarDirectiveTests {
    private func makeDirective(name: String = "title") -> SidecarDirective {
        SidecarDirective(
            name: name,
            instruction: "Generate a short title. Return null to decline.",
            schema: .string(),
            streaming: .buffered
        )
    }

    @Test func directiveRoundTripsThroughCodable() throws {
        let directive = makeDirective()
        let data = try JSONEncoder().encode(directive)
        let decoded = try JSONDecoder().decode(SidecarDirective.self, from: data)
        #expect(decoded == directive)
    }

    @Test func reservedResponseNameIsInvalid() {
        #expect(SidecarDirective.reservedFieldName == "response")
        #expect(!makeDirective(name: "response").hasValidName)
        #expect(makeDirective(name: "title").hasValidName)
    }

    @Test func emptyNameIsInvalid() {
        #expect(!makeDirective(name: "").hasValidName)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SidecarDirectiveTests`
Expected: FAIL — `SidecarDirective` not found.

- [ ] **Step 3: Implement**

```swift
import Foundation
import struct JSONSchema.Schema

/// A piggy-backed auxiliary generation riding a chat turn's structured output.
///
/// The chat turn's combined JSON schema gains one field per directive (keyed by `name`),
/// generated from the same context as the user-visible `response`. Consumers receive
/// directive values through `ChatEvent.delta(.sidecar)` / `.completion(.sidecarsCompleted)`
/// and must treat missing/declined values as non-errors.
public struct SidecarDirective: Sendable, Equatable, Codable {
    /// How the directive's value is delivered while streaming.
    public enum StreamingMode: Sendable, Equatable, Codable {
        /// Deliver once, when the field's value is complete.
        case buffered
        /// Deliver growing partial values as they stream (long fields, e.g. summaries).
        case incremental
    }

    /// The JSON field name reserved for the user-visible response in composed schemas.
    public static let reservedFieldName = "response"

    /// JSON field name in the combined schema. Must be unique per turn and not `response`.
    public let name: String
    /// Prompt text describing what to produce (injected into the turn's instructions).
    public let instruction: String
    /// Schema fragment for this field. Make it nullable to let the model decline.
    public let schema: Schema
    public let streaming: StreamingMode

    public init(name: String, instruction: String, schema: Schema, streaming: StreamingMode = .buffered) {
        self.name = name
        self.instruction = instruction
        self.schema = schema
        self.streaming = streaming
    }

    /// Structural name validity (non-empty, not the reserved response field).
    /// Cross-directive uniqueness is validated by `SidecarSchemaComposer`.
    public var hasValidName: Bool {
        !name.isEmpty && name != Self.reservedFieldName
    }
}
```

Note: `Schema` (swift-json-schema) is `Codable`/`Equatable`/`Sendable` — `StructuredOutputSchema` in this same directory already relies on that.

- [ ] **Step 4: Run tests**

Run: `swift test --filter SidecarDirectiveTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PKShared/SharedTypes/SidecarDirective.swift Tests/PKSharedTests/SidecarDirectiveTests.swift
git commit -m "feat: SidecarDirective shared type"
```

---

### Task 3: Sidecar event payloads + `ChatEvent` cases

**Files:**
- Create: `PositronicKit/Sources/PKShared/SharedTypes/SidecarEvents.swift`
- Modify: `PositronicKit/Sources/PKShared/SharedTypes/ChatEvent.swift` (`DeltaEvent` `:56-66`, `CompletionEvent` `:91-98`, factory extension `:108-163`, accessors `:167-185`)
- Test: `PositronicKit/Tests/PKSharedTests/SidecarEventsTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
@testable import PKShared

@Suite struct SidecarEventsTests {
    @Test func sidecarDeltaEventRoundTrips() throws {
        let event = ChatEvent.sidecar(SidecarDelta(name: "title", partialText: "Refactoring the", isFinal: false))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ChatEvent.self, from: data)
        #expect(decoded.sidecarDelta?.name == "title")
        #expect(decoded.sidecarDelta?.partialText == "Refactoring the")
        #expect(decoded.sidecarDelta?.isFinal == false)
    }

    @Test func sidecarsCompletedCarriesValuesAndErrors() throws {
        let results = [
            SidecarResult(name: "title", outcome: .value(AnyCodable("A Title"))),
            SidecarResult(name: "tone", outcome: .declined),
            SidecarResult(name: "memory", outcome: .failed(reason: "field never completed")),
        ]
        let event = ChatEvent.sidecarsCompleted(results)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ChatEvent.self, from: data)
        #expect(decoded.sidecarResults?.count == 3)
        #expect(decoded.sidecarResults?[1].outcome == .declined)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SidecarEventsTests`
Expected: FAIL — types not found.

- [ ] **Step 3: Implement payload types** (`SidecarEvents.swift`)

```swift
import Foundation

/// Streaming update for a single sidecar directive field.
public struct SidecarDelta: Sendable, Equatable, Codable {
    public let name: String
    /// Best-effort partial text for `.incremental` directives; complete text on the final delta.
    public let partialText: String
    public let isFinal: Bool

    public init(name: String, partialText: String, isFinal: Bool) {
        self.name = name
        self.partialText = partialText
        self.isFinal = isFinal
    }
}

/// Final outcome of one sidecar directive for the turn.
public struct SidecarResult: Sendable, Equatable, Codable {
    public enum Outcome: Sendable, Equatable, Codable {
        /// Parsed value for the field.
        case value(AnyCodable)
        /// The model explicitly returned `null` — a valid non-answer, not an error.
        case declined
        /// The field never completed / failed to parse. Best-effort partial text, if any,
        /// is carried in `SidecarDelta`s already emitted.
        case failed(reason: String)
    }

    public let name: String
    public let outcome: Outcome

    public init(name: String, outcome: Outcome) {
        self.name = name
        self.outcome = outcome
    }
}
```

(`AnyCodable` already exists at `Sources/PKShared/SharedTypes/AnyCodable.swift` and is the repo's JSON-value currency for tool args. Verify it is `Equatable`; if not, add conformance there.)

- [ ] **Step 4: Add `ChatEvent` cases, factories, accessors**

In `ChatEvent.DeltaEvent` add:

```swift
/// Sidecar directive field update (piggy-backed structured output)
case sidecar(delta: SidecarDelta)
```

In `ChatEvent.CompletionEvent` add:

```swift
/// All sidecar directives resolved for the turn (values, declines, failures)
case sidecarsCompleted(results: [SidecarResult])
```

Factory extension additions (matching existing style):

```swift
static func sidecar(_ delta: SidecarDelta) -> ChatEvent {
    .delta(event: .sidecar(delta: delta))
}

static func sidecarsCompleted(_ results: [SidecarResult]) -> ChatEvent {
    .completion(event: .sidecarsCompleted(results: results))
}
```

Accessor extension additions:

```swift
/// The sidecar delta if this is a `.delta(.sidecar(...))` event.
var sidecarDelta: SidecarDelta? {
    if case let .delta(event) = self, case let .sidecar(delta) = event { return delta }
    return nil
}

/// The sidecar results if this is a `.completion(.sidecarsCompleted(...))` event.
var sidecarResults: [SidecarResult]? {
    if case let .completion(event) = self, case let .sidecarsCompleted(results) = event { return results }
    return nil
}
```

- [ ] **Step 5: Fix PK-internal exhaustive switches**

Run: `swift build 2>&1 | grep -n "switch must be exhaustive"` and add cases where the compiler demands (search `grep -rn "case .delta" Sources Tests` for candidates; consumers that only care about text should add explicit no-op cases, not `default:`).

- [ ] **Step 6: Run tests**

Run: `swift test --filter SidecarEventsTests && swift test --filter ChatEvent`
Expected: PASS, no regressions in existing ChatEvent tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/PKShared/SharedTypes/SidecarEvents.swift Sources/PKShared/SharedTypes/ChatEvent.swift Tests/PKSharedTests/SidecarEventsTests.swift
git commit -m "feat: sidecar ChatEvent cases (SidecarDelta, SidecarResult)"
```

---

### Task 4: `SidecarSchemaComposer` (schema + instruction composition, validation)

**Files:**
- Create: `PositronicKit/Sources/PositronicKit/Services/Chat/SidecarSchemaComposer.swift`
- Create: `PositronicKit/Sources/PositronicKit/Services/Chat/SidecarError.swift`
- Test: `PositronicKit/Tests/PositronicKitTests/SidecarSchemaComposerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import struct JSONSchema.Schema
import PKShared
@testable import PositronicKit

@Suite struct SidecarSchemaComposerTests {
    private let title = SidecarDirective(
        name: "title", instruction: "Short title; null to decline.",
        schema: .string(), streaming: .buffered
    )
    private let tone = SidecarDirective(
        name: "tone", instruction: "One-word tone.",
        schema: .string(), streaming: .buffered
    )

    @Test func composesResponseFirstWithAllFieldsRequired() throws {
        let request = try SidecarSchemaComposer.compose(directives: [title, tone])
        guard case let .jsonSchema(schema) = request else {
            Issue.record("expected .jsonSchema"); return
        }
        #expect(schema.strict)
        let encoded = try JSONEncoder().encode(schema.schema)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let properties = object?["properties"] as? [String: Any]
        #expect(properties?.keys.sorted() == ["response", "title", "tone"])
        let required = object?["required"] as? [String]
        #expect(required?.first == "response")
        #expect(Set(required ?? []) == ["response", "title", "tone"])
        // Property ORDER: response must be declared first (steers generation order).
        let raw = String(decoding: encoded, as: UTF8.self)
        let responseIdx = raw.range(of: "\"response\"")!.lowerBound
        #expect(raw.range(of: "\"title\"")!.lowerBound > responseIdx)
    }

    @Test func duplicateNamesThrow() {
        #expect(throws: SidecarError.self) {
            _ = try SidecarSchemaComposer.compose(directives: [title, title])
        }
    }

    @Test func reservedNameThrows() {
        let bad = SidecarDirective(name: "response", instruction: "x", schema: .string(), streaming: .buffered)
        #expect(throws: SidecarError.self) {
            _ = try SidecarSchemaComposer.compose(directives: [bad])
        }
    }

    @Test func instructionBlockListsEveryDirective() {
        let block = SidecarSchemaComposer.instructionBlock(directives: [title, tone])
        #expect(block.contains("title"))
        #expect(block.contains("Short title; null to decline."))
        #expect(block.contains("tone"))
        #expect(block.contains("response"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SidecarSchemaComposerTests`
Expected: FAIL — types not found.

- [ ] **Step 3: Implement `SidecarError`**

```swift
import ErrorKit
import PKShared

/// Validation errors for sidecar directive composition.
public enum SidecarError: Error, Sendable, Equatable {
    case duplicateDirectiveNames([String])
    case reservedOrInvalidName(String)
    case conflictsWithExplicitStructuredOutput
}

extension SidecarError: PKError {
    public var errorDomain: String { PKErrorDomain.chat }
    public var errorCode: Int {
        switch self {
        case .duplicateDirectiveNames: return 5101
        case .reservedOrInvalidName: return 5102
        case .conflictsWithExplicitStructuredOutput: return 5103
        }
    }
    public var userFriendlyMessage: String {
        switch self {
        case let .duplicateDirectiveNames(names):
            return "Sidecar directive names must be unique; duplicates: \(names.joined(separator: ", "))."
        case let .reservedOrInvalidName(name):
            return "Sidecar directive name '\(name)' is empty or reserved."
        case .conflictsWithExplicitStructuredOutput:
            return "A turn cannot use both sidecar directives and an explicit structuredOutput request."
        }
    }
}
```

(Domains live in `Sources/PKShared/Utilities/PKError.swift:22-40` — `chat` is the closest; verify it exists and that codes 51xx don't collide (`grep -rn "errorCode" Sources | grep 51`). Adjust domain/codes if taken.)

- [ ] **Step 4: Implement composer**

```swift
import Foundation
import JSONSchema
import PKShared

/// Pure composition of a combined structured-output request + instruction block
/// from a set of sidecar directives. No ChatEngine state; fully unit-testable.
enum SidecarSchemaComposer {
    /// Combined schema: `response` (string) declared first, then one property per
    /// directive, all required, strict. Field order matters — models generate object
    /// fields roughly in declaration order, keeping the user-visible response streaming first.
    static func compose(directives: [SidecarDirective]) throws -> StructuredOutputRequest {
        try validate(directives)

        var properties: [String: Schema] = [:]
        var order: [String] = [SidecarDirective.reservedFieldName]
        properties[SidecarDirective.reservedFieldName] = .string(
            description: "The assistant's reply to the user. Markdown allowed."
        )
        for directive in directives {
            properties[directive.name] = directive.schema
            order.append(directive.name)
        }

        // NOTE: verify how swift-json-schema 0.11.2 expresses property order in its
        // object schema builder (`propertyOrder`/ordered dictionary/emission order).
        // The test in Step 1 pins the observable requirement: `response` serializes first
        // and `required` lists it first. If the library cannot guarantee key emission
        // order, encode the object schema manually via its raw-schema initializer.
        let objectSchema = Schema.object(
            properties: properties,
            required: order,
            additionalProperties: false
        )

        return .jsonSchema(StructuredOutputSchema(
            name: "sidecar_turn",
            description: "User-visible response plus piggy-backed auxiliary fields.",
            schema: objectSchema,
            strict: true
        ))
    }

    /// Instruction text appended to the turn's system instructions.
    static func instructionBlock(directives: [SidecarDirective]) -> String {
        var lines: [String] = [
            "",
            "## Piggy-backed fields",
            "Reply as a single JSON object. Put your normal reply to the user in the \"response\" field first.",
            "Additionally produce these fields from the same conversation context:",
        ]
        for directive in directives {
            lines.append("- \"\(directive.name)\": \(directive.instruction)")
        }
        return lines.joined(separator: "\n")
    }

    static func validate(_ directives: [SidecarDirective]) throws {
        for directive in directives where !directive.hasValidName {
            throw SidecarError.reservedOrInvalidName(directive.name)
        }
        let names = directives.map(\.name)
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $1.count > 1 }.keys
        if !duplicates.isEmpty {
            throw SidecarError.duplicateDirectiveNames(duplicates.sorted())
        }
    }
}
```

Exact `Schema` builder syntax: mirror how `StructuredOutputFixtures` / `PositronicKitUsageExamples.makeStructuredOutputSchema()` (`Sources/PositronicKitExamples/PositronicKitUsageExamples.swift:94-104`) construct object schemas, and adjust.

- [ ] **Step 5: Run tests**

Run: `swift test --filter SidecarSchemaComposerTests`
Expected: PASS (4 tests). If the property-order assertion cannot pass with the builder API, switch to raw-schema construction (see NOTE) before moving on — do not weaken the test.

- [ ] **Step 6: Commit**

```bash
git add Sources/PositronicKit/Services/Chat/SidecarSchemaComposer.swift Sources/PositronicKit/Services/Chat/SidecarError.swift Tests/PositronicKitTests/SidecarSchemaComposerTests.swift
git commit -m "feat: sidecar schema/instruction composer with validation"
```

---

### Task 5: `SidecarStreamExtractor` (incremental extraction core)

The heart of the feature: a synchronous, single-owner state machine consuming raw JSON text deltas and emitting routed events. Owning it as a plain `struct` driven from `LLMStreamingStage`'s existing delta loop keeps concurrency out of the parser.

**Files:**
- Create: `PositronicKit/Sources/PositronicKit/Services/Chat/SidecarStreamExtractor.swift`
- Test: `PositronicKit/Tests/PositronicKitTests/SidecarStreamExtractorTests.swift`

- [ ] **Step 1: Write failing tests (the full behavior matrix)**

```swift
import Testing
import PKShared
@testable import PositronicKit

@Suite struct SidecarStreamExtractorTests {
    private func makeExtractor(
        directives: [SidecarDirective] = [
            .init(name: "title", instruction: "t", schema: .string(), streaming: .buffered),
            .init(name: "summary", instruction: "s", schema: .string(), streaming: .incremental),
        ]
    ) -> SidecarStreamExtractor {
        SidecarStreamExtractor(directives: directives)
    }

    /// Feed `chunks` and collect all outputs.
    private func run(_ chunks: [String], extractor: inout SidecarStreamExtractor) -> [SidecarStreamExtractor.Output] {
        var outputs: [SidecarStreamExtractor.Output] = []
        for chunk in chunks { outputs += extractor.consume(chunk) }
        outputs += extractor.finish()
        return outputs
    }

    @Test func responseFieldStreamsAsSuffixDeltas() {
        var extractor = makeExtractor()
        let outputs = run([
            #"{"response": "Hel"#,
            #"lo there"#,
            #"", "title": "Greeting", "summary": "Said hi"}"#,
        ], extractor: &extractor)
        let responseText = outputs.compactMap { if case let .responseDelta(t) = $0 { t } else { nil } }.joined()
        #expect(responseText == "Hello there")
        // Raw JSON syntax must never leak into response deltas.
        #expect(!responseText.contains("{"))
        #expect(!responseText.contains("\"title\""))
    }

    @Test func responseSuffixAcrossEscapeSplitBoundary() {
        var extractor = makeExtractor()
        // Chunk boundary splits the \" escape inside the response string.
        let outputs = run([
            #"{"response": "say \"#,
            #""hi\"", "title": "T", "summary": "S"}"#,
        ], extractor: &extractor)
        let text = outputs.compactMap { if case let .responseDelta(t) = $0 { t } else { nil } }.joined()
        #expect(text == #"say "hi""#)
    }

    @Test func bufferedDirectiveDeliversOnceComplete() {
        var extractor = makeExtractor()
        let outputs = run([
            #"{"response": "ok", "title": "A ti"#,
            #"tle", "summary": "x"}"#,
        ], extractor: &extractor)
        let titleDeltas = outputs.compactMap { if case let .sidecarDelta(d) = $0, d.name == "title" { d } else { nil } }
        #expect(titleDeltas.count == 1)
        #expect(titleDeltas[0].partialText == "A title")
        #expect(titleDeltas[0].isFinal)
    }

    @Test func incrementalDirectiveDeliversPartials() {
        var extractor = makeExtractor()
        let outputs = run([
            #"{"response": "ok", "title": "T", "summary": "part one"#,
            #" and part two"}"#,
        ], extractor: &extractor)
        let deltas = outputs.compactMap { if case let .sidecarDelta(d) = $0, d.name == "summary" { d } else { nil } }
        #expect(deltas.count >= 2)
        #expect(deltas.last?.isFinal == true)
        #expect(deltas.last?.partialText == "part one and part two")
    }

    @Test func lastFieldCompletesAtObjectClose() {
        // Spec-review note: the LAST field only completes when the object closes.
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: .string(), streaming: .buffered)
        ])
        var outputs = extractor.consume(#"{"response": "ok", "title": "The End""#)
        #expect(outputs.compactMap { if case let .sidecarDelta(d) = $0 { d } else { nil } }.isEmpty)
        outputs = extractor.consume("}")
        let final = outputs.compactMap { if case let .sidecarDelta(d) = $0 { d } else { nil } }
        #expect(final.count == 1 && final[0].isFinal && final[0].partialText == "The End")
    }

    @Test func nullValueYieldsDeclinedResult() {
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: .string(), streaming: .buffered)
        ])
        let outputs = run([#"{"response": "ok", "title": null}"#], extractor: &extractor)
        let results = outputs.compactMap { if case let .completed(r) = $0 { r } else { nil } }.flatMap { $0 }
        #expect(results == [SidecarResult(name: "title", outcome: .declined)])
    }

    @Test func truncatedStreamFailsIncompleteDirectivesKeepsResponse() {
        var extractor = makeExtractor()
        let outputs = run([#"{"response": "partial answer", "title": "Tru"#], extractor: &extractor)
        let text = outputs.compactMap { if case let .responseDelta(t) = $0 { t } else { nil } }.joined()
        #expect(text == "partial answer")
        let results = outputs.compactMap { if case let .completed(r) = $0 { r } else { nil } }.flatMap { $0 }
        #expect(results.contains { $0.name == "summary" && $0.outcome == .failed(reason: "field missing at stream end") })
        // title got partial text -> failed with best-effort semantics
        #expect(results.contains { $0.name == "title" })
    }

    @Test func nonJSONOutputFallsBackToPassthrough() {
        var extractor = makeExtractor()
        let outputs = run(["I'm sorry, I can't produce JSON right now."], extractor: &extractor)
        let text = outputs.compactMap { if case let .responseDelta(t) = $0 { t } else { nil } }.joined()
        #expect(text == "I'm sorry, I can't produce JSON right now.")
        let results = outputs.compactMap { if case let .completed(r) = $0 { r } else { nil } }.flatMap { $0 }
        #expect(results.allSatisfy { if case .failed = $0.outcome { true } else { false } })
    }

    @Test func nonStringDirectiveValueDeliveredAsValue() {
        var extractor = makeExtractor(directives: [
            .init(name: "confidence", instruction: "c", schema: .number(), streaming: .buffered)
        ])
        let outputs = run([#"{"response": "ok", "confidence": 0.83}"#], extractor: &extractor)
        let results = outputs.compactMap { if case let .completed(r) = $0 { r } else { nil } }.flatMap { $0 }
        #expect(results.first?.outcome == .value(AnyCodable(0.83)))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SidecarStreamExtractorTests`
Expected: FAIL — type not found.

- [ ] **Step 3: Implement**

```swift
import Foundation
import PartialJSON
import PKShared

/// Incremental extractor turning raw structured-output JSON deltas into routed
/// sidecar-turn outputs. Pure value type: feed `consume(_:)` per content delta,
/// call `finish()` at stream end. Not thread-safe by design — owned and driven
/// solely by `LLMStreamingStage`'s delta loop.
struct SidecarStreamExtractor {
    enum Output: Equatable {
        /// New suffix of the user-visible `response` field.
        case responseDelta(String)
        /// Partial or final sidecar field text.
        case sidecarDelta(SidecarDelta)
        /// Terminal per-directive outcomes (emitted once, from `finish()` or object close).
        case completed([SidecarResult])
    }

    private let directives: [SidecarDirective]
    private var buffer = ""
    private var emittedResponsePrefix = ""
    private var emittedSidecarPrefixes: [String: String] = [:]
    private var finalizedFields: Set<String> = []
    private var completedEmitted = false
    /// Passthrough mode: buffer never became a JSON object — treat everything as response.
    private var passthrough = false
    private var passthroughDecided = false

    /// Chars of non-whitespace prefix to inspect before deciding the model ignored the schema.
    private static let passthroughDecisionWindow = 16

    init(directives: [SidecarDirective]) {
        self.directives = directives
    }

    mutating func consume(_ delta: String) -> [Output] {
        buffer += delta

        if !passthroughDecided {
            let head = buffer.drop(while: { $0.isWhitespace })
            if head.isEmpty { return [] }
            // Decide on the first non-whitespace character: an object opener means JSON
            // mode; anything else means the model ignored the schema → passthrough.
            // (`passthroughDecisionWindow` exists for a stricter variant — requiring
            // `{"` + a known key within the window — adopt it only if first-char
            // detection proves too eager against real model output.)
            passthrough = head.first != "{"
            passthroughDecided = true
        }

        if passthrough {
            let out = buffer
            buffer = "" // response text is tracked via emittedResponsePrefix in JSON mode only
            return out.isEmpty ? [] : [.responseDelta(out)]
        }

        return reparse()
    }

    mutating func finish() -> [Output] {
        var outputs: [Output] = []
        if passthrough {
            outputs.append(.completed(directives.map {
                SidecarResult(name: $0.name, outcome: .failed(reason: "model did not produce structured output"))
            }))
            completedEmitted = true
            return outputs
        }

        // Final reparse; then resolve every directive.
        outputs += reparse(atEnd: true)
        guard !completedEmitted else { return outputs }
        var results: [SidecarResult] = []
        let parsed = currentParse()
        for directive in directives {
            if let object = parsed {
                if object[directive.name] is NSNull {
                    results.append(SidecarResult(name: directive.name, outcome: .declined))
                    continue
                }
                if finalizedFields.contains(directive.name), let value = object[directive.name] {
                    results.append(SidecarResult(name: directive.name, outcome: .value(AnyCodable(value))))
                    continue
                }
                if object[directive.name] != nil {
                    results.append(SidecarResult(
                        name: directive.name,
                        outcome: .failed(reason: "field incomplete at stream end")
                    ))
                    continue
                }
            }
            results.append(SidecarResult(name: directive.name, outcome: .failed(reason: "field missing at stream end")))
        }
        completedEmitted = true
        outputs.append(.completed(results))
        return outputs
    }

    // MARK: - Parsing

    /// Best-effort parse of the whole buffer via PartialJSON (partial strings allowed).
    private func currentParse() -> [String: Any]? {
        (try? PartialJSON.parse(buffer, options: .all)) as? [String: Any]
    }

    private mutating func reparse(atEnd: Bool = false) -> [Output] {
        guard let object = currentParse() else { return [] }
        var outputs: [Output] = []

        // 1. response suffix
        if let response = object[SidecarDirective.reservedFieldName] as? String,
           response.hasPrefix(emittedResponsePrefix), response.count > emittedResponsePrefix.count {
            let suffix = String(response.dropFirst(emittedResponsePrefix.count))
            emittedResponsePrefix = response
            outputs.append(.responseDelta(suffix))
        }

        // 2. field completion: a field is final when a later sibling key has appeared
        //    in the raw buffer, or the object has closed (balanced braces / atEnd parse).
        let closed = objectClosed()
        for (index, directive) in directives.enumerated() {
            guard !finalizedFields.contains(directive.name) else { continue }
            guard object[directive.name] != nil else { continue }

            if object[directive.name] is NSNull {
                if closed || laterKeyStarted(after: index) {
                    finalizedFields.insert(directive.name)
                }
                continue // declines surface only in `completed` results
            }

            let text = stringRepresentation(object[directive.name])
            let previous = emittedSidecarPrefixes[directive.name] ?? ""
            let isFinal = closed || laterKeyStarted(after: index)

            if isFinal {
                finalizedFields.insert(directive.name)
                outputs.append(.sidecarDelta(SidecarDelta(name: directive.name, partialText: text, isFinal: true)))
                emittedSidecarPrefixes[directive.name] = text
            } else if directive.streaming == .incremental, text != previous {
                outputs.append(.sidecarDelta(SidecarDelta(name: directive.name, partialText: text, isFinal: false)))
                emittedSidecarPrefixes[directive.name] = text
            }
        }
        return outputs
    }

    /// True when the top-level object's braces are balanced in the raw buffer
    /// (string-aware scan; quotes and escapes respected).
    private func objectClosed() -> Bool {
        var depth = 0, inString = false, escaped = false, seenOpen = false
        for char in buffer {
            if escaped { escaped = false; continue }
            switch char {
            case "\\" where inString: escaped = true
            case "\"": inString.toggle()
            case "{" where !inString: depth += 1; seenOpen = true
            case "}" where !inString: depth -= 1
            default: break
            }
        }
        return seenOpen && depth == 0
    }

    /// True when any key that would come after `index` (directive order) — or any
    /// unknown later key — has appeared in the raw buffer as `"name"` followed by `:`.
    private func laterKeyStarted(after index: Int) -> Bool {
        let laterNames = directives.suffix(from: directives.index(after: index)).map(\.name)
        return laterNames.contains { rawKeyPresent($0) }
    }

    private func rawKeyPresent(_ name: String) -> Bool {
        // Raw-buffer scan is a heuristic; the parse in `currentParse()` is authoritative
        // for values. Key collision with content strings is acceptable at worst as an
        // early-final of an already-complete previous field.
        buffer.contains("\"\(name)\"")
    }

    private func stringRepresentation(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let some?:
            if let data = try? JSONSerialization.data(withJSONObject: some, options: [.fragmentsAllowed]) {
                return String(decoding: data, as: UTF8.self)
            }
            return String(describing: some)
        case nil: return ""
        }
    }
}
```

Implementation notes for the executor:
- `PartialJSON.parse` API is as documented in the repo README (`parse(_:options:)` → `Any`, options set with `.all` allowing partial strings/collections). If names differ, adapt only this file.
- The `response.hasPrefix(emittedResponsePrefix)` guard protects against a re-parse producing *different* earlier text (shouldn't happen with append-only streaming, but never emit a broken suffix — if the prefix check fails, emit nothing for that reparse).
- O(n²) reparse per delta is accepted per spec (chat-sized payloads).

- [ ] **Step 4: Run tests, iterate until green**

Run: `swift test --filter SidecarStreamExtractorTests`
Expected: PASS (10 tests). Escape-boundary and last-field tests are the likely iterations.

- [ ] **Step 5: Commit**

```bash
git add Sources/PositronicKit/Services/Chat/SidecarStreamExtractor.swift Tests/PositronicKitTests/SidecarStreamExtractorTests.swift
git commit -m "feat: SidecarStreamExtractor incremental JSON field extraction"
```

---

### Task 6: Wire sidecars through `ChatTurnContext`, `TurnOutputs`, and `LLMStreamingStage`

**Files:**
- Modify: `PositronicKit/Sources/PositronicKit/Services/Chat/ChatTurnContext.swift` (add `sidecars` to context `:83-176`; add sidecar accumulation to `TurnOutputs` `:20-79`)
- Modify: `PositronicKit/Sources/PositronicKit/Services/Chat/Stages/LLMStreamingStage.swift` (`process` `:18-34`, `streamResponse` `:79-101`, `handleContentDelta` `:109-142`, `flushRemainingBuffer` `:187-204`)
- Test: `PositronicKit/Tests/PositronicKitTests/SidecarStreamingStageTests.swift`

- [ ] **Step 1: Write failing stage-level tests**

Use the existing mock LLM service from `PKTestSupport` (see `StructuredOutputServiceTests` for the scripted-chunk pattern). Cover:

```swift
// 1. sidecar turn: .generation events carry only extracted response text (never raw JSON);
//    .sidecar deltas arrive; TurnOutputs.fullResponse == extracted response text only.
// 2. no-sidecars turn: event stream byte-identical to today's behavior for the same chunks
//    (pinning test for the SDC-5 no-op guarantee).
// 3. thinking deltas (structured field) still pass through unchanged on sidecar turns.
// 4. mid-stream provider error: already-emitted response deltas stand; stage rethrows as today.
```

Write these as concrete tests scripting chunk sequences through the stage and collecting `ChatEvent`s.

- [ ] **Step 2: Run to verify failure** (`swift test --filter SidecarStreamingStageTests`)

- [ ] **Step 3: Context + outputs plumbing**

`ChatTurnContext`: add `let sidecars: [SidecarDirective]` (default `[]`) — init param after `structuredOutput` (`:119`), stored `:136`, threaded in `forTurn` (`:157-174`).

`TurnOutputs`: add

```swift
private(set) var sidecarResults: [SidecarResult] = []

func setSidecarResults(_ results: [SidecarResult]) {
    sidecarResults = results
}
```

`fullResponse` on sidecar turns accumulates only extracted response text (the stage routes it, below) — persisted messages therefore contain no raw JSON, satisfying the spec's history-poisoning rule with **no change** to `MessagePersistenceStage`. Verify by reading `MessagePersistenceStage` before starting; if it reads anything besides `outputs.fullResponse`/`fullThinking`/tool accumulators, account for it.

- [ ] **Step 4: Stage wiring**

In `LLMStreamingStage.process` (`:20-26`): when `!context.sidecars.isEmpty`, compose the structured request via `SidecarSchemaComposer.compose(directives:)` and pass it to the existing `chatStream(structuredOutput:)` call. (Precedence/conflict with explicit `structuredOutput` is enforced upstream in Task 7 — the stage may `assert` both aren't set.)

In `streamResponse`: create `var extractor: SidecarStreamExtractor?` when sidecars are present; in `handleContentDelta`, when an extractor exists, bypass the `StreamingParser` content path and instead:

```swift
guard let delta = result.choices.first?.delta.content else { return }
for output in extractor.consume(delta) {
    switch output {
    case let .responseDelta(text):
        await context.outputs.appendResponse(text)
        continuation.yield(.generation(text))
    case let .sidecarDelta(sidecarDelta):
        continuation.yield(.sidecar(sidecarDelta))
    case let .completed(results):
        await context.outputs.setSidecarResults(results)
        continuation.yield(.sidecarsCompleted(results))
    }
}
```

(Structured-output turns emit JSON in `content`; `<think>` scraping doesn't apply — but structured `delta.thinking` still routes through `handleStructuredThinkingDelta` untouched.)

After the delta loop (where `flushRemainingBuffer` runs today), call `extractor.finish()` and route its outputs the same way, then `finalizeTurn` as today. Skip `flushRemainingBuffer`'s parser path when the extractor is active (the parser was never fed).

- [ ] **Step 5: Run stage tests + full suite**

Run: `swift test --filter SidecarStreamingStageTests && swift test`
Expected: new tests PASS; zero regressions (watch `LLMStreamingStage`-adjacent suites and PKR-2-related tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/PositronicKit/Services/Chat/ Tests/PositronicKitTests/SidecarStreamingStageTests.swift
git commit -m "feat: wire sidecar extraction through LLMStreamingStage and TurnOutputs"
```

---

### Task 7: `ChatEngine.execute(sidecars:)` entry point + integration tests

**Files:**
- Modify: `PositronicKit/Sources/PositronicKit/Services/Chat/ChatEngine.swift` (`execute` signature `:81-95`, `prepareSession` call `:104-118`) and `ChatEngine+ContextBuilding.swift` (`prepareSession` `:47+`, systemInstructions composition)
- Modify: any public wrapper that forwards to `ChatEngine.execute` (grep `execute(` callers in `TimelineManager`/public API — mirror the parameter there so consumers can actually reach it)
- Test: `PositronicKit/Tests/PositronicKitTests/SidecarTurnIntegrationTests.swift`

- [ ] **Step 1: Write failing integration tests**

Through the public entry point with `PKTestSupport` runtime/mocks:

```swift
// 1. Turn with [title, tone] directives: user sees streamed response only;
//    .sidecarsCompleted carries both; persisted assistant message content == response text.
// 2. executeTurn(structuredOutput: X, sidecars: [Y]) throws SidecarError.conflictsWithExplicitStructuredOutput.
// 3. Instruction block present: captured LLM request messages contain each directive's
//    instruction text; combined schema present in the request's structured output.
// 4. Sidecars + tool-call round: tool call executes, final generation carries the combined
//    schema, sidecar results still resolve (mirror an existing multi-turn tool test's scripting).
// 5. Turn with sidecars: [] behaves identically to a turn without the parameter (event-type sequence equality).
```

- [ ] **Step 2: Run to verify failure**

- [ ] **Step 3: Implement**

`execute(...)` gains `sidecars: [SidecarDirective] = []` after `structuredOutput`. Guard at top:

```swift
guard structuredOutput == nil || sidecars.isEmpty else {
    throw SidecarError.conflictsWithExplicitStructuredOutput
}
```

`prepareSession` threads `sidecars` into `ChatTurnContext` and, when non-empty, appends `SidecarSchemaComposer.instructionBlock(directives:)` to the effective system instructions (exact seam: wherever `systemInstructions` is resolved before prompt assembly in `ChatEngine+ContextBuilding.swift` — keep it one `+` concatenation at that seam, no deeper prompt-logic branching). Also run `SidecarSchemaComposer.validate(directives)` here so invalid directives throw before any LLM call.

- [ ] **Step 4: Run integration tests + full verify**

Run: `swift test --filter SidecarTurnIntegrationTests && make verify`
Expected: PASS; verify gate green (check the executed-test count is nonzero — see PKFastEmbed pitfall).

- [ ] **Step 5: Commit**

```bash
git add Sources/PositronicKit/Services/Chat/ Tests/PositronicKitTests/SidecarTurnIntegrationTests.swift
git commit -m "feat: ChatEngine sidecar directives entry point"
```

---

### Task 8: Examples + docs

**Files:**
- Modify: `PositronicKit/Sources/PositronicKitExamples/PositronicKitUsageExamples.swift`, `main.swift`
- Modify: `PositronicKit/Sources/PositronicKit/docs/Architecture.md` (pipeline/stage section), `PositronicKit/docs/API_REFERENCE.md` if present (check `ls docs`)

- [ ] **Step 1: Add a compiling sidecar example**

`makeSidecarDirectives()` returning a `title` (nullable-string, buffered, declinable-instruction) + `tone` (enum) pair, and a commented `executeTurn(sidecars:)` consumption sketch showing `.generation` vs `.sidecar` routing. Print composed schema in `main.swift` alongside the existing structured-output prints. (Full example expansion is ticket SDC-6 — here just enough that the new public API appears in living docs.)

- [ ] **Step 2: Verify examples run**

Run: `swift run PositronicKitExamples`
Expected: exits 0, prints sidecar schema.

- [ ] **Step 3: Update architecture docs**

Document: sidecar flow (composer → combined schema → streaming stage extractor → events), event cases, error model ("sidecar failure never fails the turn"), and the SDC-5 no-op guarantee.

- [ ] **Step 4: Commit**

```bash
git add Sources/PositronicKitExamples/ Sources/PositronicKit/docs/
git commit -m "docs: sidecar directives example and architecture notes"
```

---

### Task 9: Full gate, downstream builds, push (WS-1)

- [ ] **Step 1: Full verification**

Run: `cd /Volumes/Development/monad-project/PositronicKit && make verify && make verify-products`
Expected: green; nonzero executed tests.

- [ ] **Step 2: Downstream sibling builds (new ChatEvent cases)**

Run: `cd ../Monad && swift build && swift test` and `cd ../Shuttle && swift build && swift test`
Expected: if exhaustive `ChatEvent` switches break, add explicit no-op cases in those repos (commit separately in each repo: `"chore: handle sidecar ChatEvent cases"`). Follow the downstream-sync checklist (`workflow/workspace/plans/2026-07-02-downstream-sync-checklist.md`).

- [ ] **Step 3: Push PositronicKit to remote `main`**

Per WS-1 (remote checkout model): `git push` from `PositronicKit` so Yakamoz's remote dependency can resolve the new API. Commit/push Monad and Shuttle changes if any.

- [ ] **Step 4: Mark plan complete; hand off to the Yakamoz adoption plan**

The Yakamoz plan (directives catalog, `typedReplyEnabled` gating per SDC-5, reducer routing, inspector section, SwiftData persistence — tickets SID-1/SID-2 for title/sections) is written as a separate document once this is on remote `main`.
