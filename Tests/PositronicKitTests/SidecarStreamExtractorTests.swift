import Foundation
import JSONSchemaBuilder
import PKShared
@testable import PositronicKit
import Testing

struct SidecarStreamExtractorTests {
    private func makeExtractor(
        directives: [SidecarDirective] = [
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
            .init(name: "summary", instruction: "s", schema: JSONString().definition(), streaming: .incremental),
        ]
    ) -> SidecarStreamExtractor {
        SidecarStreamExtractor(directives: directives)
    }

    /// Feed `chunks` and collect all outputs.
    private func run(_ chunks: [String], extractor: inout SidecarStreamExtractor) -> [SidecarStreamExtractor.Output] {
        var outputs: [SidecarStreamExtractor.Output] = []
        for chunk in chunks {
            outputs += extractor.consume(chunk)
        }
        outputs += extractor.finish()
        return outputs
    }

    @Test func responseFieldStreamsAsSuffixDeltas() {
        var extractor = makeExtractor()
        let outputs = run([
            #"{"response": "Hel"#,
            #"lo there"#,
            #"", "sidecar_payload": {"title": "Greeting", "summary": "Said hi"}} "#,
        ], extractor: &extractor)
        let responseText = outputs.compactMap { if case let .responseDelta(t) = $0 { t } else { nil } }.joined()
        #expect(responseText == "Hello there")
        #expect(!responseText.contains("{"))
        #expect(!responseText.contains("\"title\""))
    }

    @Test func responseSuffixAcrossEscapeSplitBoundary() {
        var extractor = makeExtractor()
        let outputs = run([
            #"{"response": "say \"#,
            #""hi\"", "sidecar_payload": {"title": "T", "summary": "S"}} "#,
        ], extractor: &extractor)
        let text = outputs.compactMap { if case let .responseDelta(t) = $0 { t } else { nil } }.joined()
        #expect(text == #"say "hi""#)
    }

    @Test func bufferedDirectiveDeliversOnceComplete() {
        var extractor = makeExtractor()
        let outputs = run([
            #"{"response": "ok", "sidecar_payload": {"title": "A ti"#,
            #"tle", "summary": "x"}} "#,
        ], extractor: &extractor)
        let titleDeltas = outputs.compactMap { if case let .sidecarDelta(d) = $0, d.name == "title" { d } else { nil } }
        #expect(titleDeltas.count == 1)
        #expect(titleDeltas[0].partialText == "A title")
        #expect(titleDeltas[0].isFinal)
    }

    @Test func incrementalDirectiveDeliversPartials() {
        var extractor = makeExtractor()
        let outputs = run([
            #"{"response": "ok", "sidecar_payload": {"title": "T", "summary": "part one"#,
            #" and part two"}} "#,
        ], extractor: &extractor)
        let deltas = outputs.compactMap { if case let .sidecarDelta(d) = $0, d.name == "summary" { d } else { nil } }
        #expect(deltas.count >= 2)
        #expect(deltas.last?.isFinal == true)
        #expect(deltas.last?.partialText == "part one and part two")
    }

    @Test func lastFieldCompletesAtObjectClose() {
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
        ])
        var outputs = extractor.consume(#"{"response": "ok", "sidecar_payload": {"title": "The End""#)
        #expect(outputs.compactMap { if case let .sidecarDelta(d) = $0 { d } else { nil } }.isEmpty)
        outputs = extractor.consume("}}")
        let final = outputs.compactMap { if case let .sidecarDelta(d) = $0 { d } else { nil } }
        #expect(final.count == 1 && final[0].isFinal && final[0].partialText == "The End")
    }

    @Test func nullValueYieldsDeclinedResult() {
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
        ])
        let outputs = run([#"{"response": "ok", "sidecar_payload": {"title": null}}"#], extractor: &extractor)
        let results = outputs.compactMap { if case let .completed(r) = $0 { r } else { nil } }.flatMap { $0 }
        #expect(results == [SidecarResult(name: "title", outcome: .declined)])
    }

    @Test func truncatedStreamFailsIncompleteDirectivesKeepsResponse() {
        var extractor = makeExtractor()
        let outputs = run([#"{"response": "partial answer", "sidecar_payload": {"title": "Tru"#], extractor: &extractor)
        let text = outputs.compactMap { if case let .responseDelta(t) = $0 { t } else { nil } }.joined()
        #expect(text == "partial answer")
        let results = outputs.compactMap { if case let .completed(r) = $0 { r } else { nil } }.flatMap { $0 }
        #expect(results.contains { $0.name == "summary" && $0.outcome == .failed(reason: "field missing at stream end") })
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
            .init(name: "confidence", instruction: "c", schema: JSONNumber().definition(), streaming: .buffered),
        ])
        let outputs = run([#"{"response": "ok", "sidecar_payload": {"confidence": 0.83}}"#], extractor: &extractor)
        let results = outputs.compactMap { if case let .completed(r) = $0 { r } else { nil } }.flatMap { $0 }
        #expect(results.first?.outcome == .value(AnyCodable(0.83)))
    }

    @Test func extractor_priorityDirectiveDeliversBeforeResponseDelta() {
        var extractor = makeExtractor(directives: [
            .init(name: "route", instruction: "r", schema: JSONString().definition(), streaming: .buffered, timing: .beforeResponse),
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
        ])
        let outputs = run([
            #"{"priority_sidecar_payload":{"route":"memory"},"response":"He"#,
            #"llo","sidecar_payload":{"title":"Greeting"}}"#,
        ], extractor: &extractor)

        let firstPriorityIndex = outputs.firstIndex {
            if case let .sidecarDelta(delta) = $0 {
                return delta.name == "route"
            }
            return false
        }
        let firstResponseIndex = outputs.firstIndex {
            if case .responseDelta = $0 { return true }
            return false
        }
        #expect(firstPriorityIndex != nil)
        #expect(firstResponseIndex != nil)
        #expect(firstPriorityIndex! < firstResponseIndex!)
    }

    @Test func extractor_priorityAndAfterResponseDirectivesBothResolve() {
        var extractor = makeExtractor(directives: [
            .init(name: "route", instruction: "r", schema: JSONString().definition(), streaming: .buffered, timing: .beforeResponse),
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered, timing: .afterResponse),
        ])
        let outputs = run([
            #"{"priority_sidecar_payload":{"route":"memory"},"response":"ok","sidecar_payload":{"title":"Greeting"}}"#,
        ], extractor: &extractor)

        let results = outputs.compactMap { if case let .completed(r) = $0 { r } else { nil } }.flatMap { $0 }
        #expect(results.contains(SidecarResult(name: "route", outcome: .value(AnyCodable("memory")))))
        #expect(results.contains(SidecarResult(name: "title", outcome: .value(AnyCodable("Greeting")))))
    }
}
