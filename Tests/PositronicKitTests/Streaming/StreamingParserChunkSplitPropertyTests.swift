import Foundation
import Testing

@testable import PositronicKit
import PKTestSupport

/// Chunk-boundary property for `StreamingParser` (issue #155).
///
/// Property: feeding a document through `process(_:)` in arbitrarily split chunks must
/// produce the same `(thinking, content)` as feeding it whole — a provider can split a
/// token anywhere in a byte stream. Bounded (`caseCount` splits per document) and
/// deterministic under a fixed seed (`PK_GENERATIVE_SEED` overrides; the effective seed
/// is reported with every failure so a failure reproduces from the log alone).
@Suite("StreamingParser chunk-split property", .tags(.generative))
struct StreamingParserChunkSplitPropertyTests {
    private let seed = GenerativeConfig.effectiveSeed()
    private let caseCount = GenerativeConfig.defaultCaseCount

    private static let alphabet = [
        "hello ", "<think>", "</think>", "reasoning ", "```", "`", "<", ">", "|",
        "<|tool_call_begin|>", "<|tool_call_end|>", "\n", "code ",
    ]

    private func decodeWhole(_ document: String) -> (thinking: String, content: String) {
        var parser = StreamingParser()
        parser.process(document)
        return (parser.thinking, parser.content)
    }

    private func decodeSplit(_ document: String, chunks: [String]) -> (thinking: String, content: String) {
        var parser = StreamingParser()
        for chunk in chunks {
            parser.process(chunk)
        }
        return (parser.thinking, parser.content)
    }

    private func randomDocuments(count: Int, seed: UInt64) -> [String] {
        var rng = SeededRNG(seed: seed ^ 0x57EED155)
        return (0 ..< count).map { _ in
            let parts = rng.nextInt(in: 1 ..< 12)
            return (0 ..< parts).map { _ in rng.nextElement(Self.alphabet) }.joined()
        }
    }

    @Test("arbitrary chunk splits decode identically to the unsplit stream")
    func chunkSplitsMatchUnsplit() {
        let documents = GenerativeRegressionCorpus.streamingDocuments
            + randomDocuments(count: 16, seed: seed)
        for (docIndex, document) in documents.enumerated() {
            let expected = decodeWhole(document)
            for chunks in ChunkBoundaryGenerator.splittings(of: document, count: caseCount, seed: seed ^ UInt64(docIndex)) {
                let actual = decodeSplit(document, chunks: chunks)
                #expect(
                    actual == expected,
                    "seed=\(seed) doc#\(docIndex) chunks=\(chunks.count): split decode \(actual) != whole decode \(expected)"
                )
            }
        }
    }

    @Test("single-character streaming matches whole-document decode")
    func characterByCharacterMatchesWhole() {
        for (docIndex, document) in GenerativeRegressionCorpus.streamingDocuments.enumerated() {
            let expected = decodeWhole(document)
            let actual = decodeSplit(document, chunks: document.map(String.init))
            #expect(
                actual == expected,
                "seed=\(seed) doc#\(docIndex): char-by-char decode \(actual) != whole decode \(expected)"
            )
        }
    }

    // MARK: - Committed regression fixtures

    /// An orphaned `</think>` split across chunk boundaries reclassifies already-emitted
    /// content into thinking — the split framing must not change that outcome.
    @Test("regression: orphaned closer split across chunks still reclassifies")
    func orphanedCloserSplitAcrossChunks() {
        let chunks = ["Some content that ", "was actually thinking </th", "ink>", " Real content"]
        var split = StreamingParser()
        for chunk in chunks { split.process(chunk) }
        var whole = StreamingParser()
        whole.process(chunks.joined())
        #expect(split.thinking == whole.thinking && split.content == whole.content)
        #expect(split.thinking.contains("Some content"))
    }

    /// A `<think>` opener fragmented byte-by-byte still opens thinking.
    @Test("regression: fragmented opener still opens thinking")
    func fragmentedOpener() {
        var parser = StreamingParser()
        for char in "<think>Inner</think>" {
            parser.process(String(char))
        }
        #expect(parser.thinking == "Inner")
        #expect(parser.content.isEmpty)
    }
}
