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
            #"", "title": "Greeting", "summary": "Said hi"}"#,
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
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
        ])
        var outputs = extractor.consume(#"{"response": "ok", "title": "The End""#)
        #expect(outputs.compactMap { if case let .sidecarDelta(d) = $0 { d } else { nil } }.isEmpty)
        outputs = extractor.consume("}")
        let final = outputs.compactMap { if case let .sidecarDelta(d) = $0 { d } else { nil } }
        #expect(final.count == 1 && final[0].isFinal && final[0].partialText == "The End")
    }

    @Test func nullValueYieldsDeclinedResult() {
        var extractor = makeExtractor(directives: [
            .init(name: "title", instruction: "t", schema: JSONString().definition(), streaming: .buffered),
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
        let outputs = run([#"{"response": "ok", "confidence": 0.83}"#], extractor: &extractor)
        let results = outputs.compactMap { if case let .completed(r) = $0 { r } else { nil } }.flatMap { $0 }
        #expect(results.first?.outcome == .value(AnyCodable(0.83)))
    }
}
