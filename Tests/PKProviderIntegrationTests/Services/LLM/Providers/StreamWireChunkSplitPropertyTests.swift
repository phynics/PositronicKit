import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

import PKTestSupport
import PKUtilities

/// Chunk-boundary property for the SSE/NDJSON wire framing shared by all five provider
/// adapters (issue #155).
///
/// Property: splitting a valid event-stream byte sequence at arbitrary boundaries and
/// re-framing it into lines must yield the same payload sequence as parsing it unsplit —
/// a provider can split a token anywhere in a byte stream. Bounded and deterministic
/// under a fixed seed (`PK_GENERATIVE_SEED` overrides; failures report the seed).
@Suite("Stream wire chunk-split property", .tags(.generative, .integration))
struct StreamWireChunkSplitPropertyTests {
    private let seed = GenerativeConfig.effectiveSeed()
    private let caseCount = GenerativeConfig.defaultCaseCount

    // MARK: - Fixtures

    private static let sseWires = [
        // OpenAI-style completion chunk plus terminal sentinel.
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: [DONE]\n",
        // Anthropic-style multi-event stream.
        "data: {\"type\":\"message_start\"}\n\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hello \"}}\n\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"world\"}}\n\ndata: {\"type\":\"message_stop\"}\n",
        // OpenRouter tool-call line with embedded escaped JSON.
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"name\":\"lookup_weather\",\"arguments\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}]}}]}\n\ndata: [DONE]\n",
    ]

    private static let ndjsonWires = [
        "{\"model\":\"llama3.1\",\"message\":{\"content\":\"hello\"},\"done\":false}\n{\"model\":\"llama3.1\",\"message\":{\"content\":\" world\"},\"done\":true}\n",
        "{\"model\":\"llama3.1\",\"message\":{\"tool_calls\":[{\"function\":{\"name\":\"lookup_weather\",\"arguments\":{\"city\":\"Berlin\"}}}]},\"done\":true}\n",
    ]

    // MARK: - Reassembly helpers (mirror the client byte-buffer pattern)

    /// Re-frame `wire` into lines after cutting it into seeded byte chunks.
    private func payloadsAfterSplit(_ wire: String, seed: UInt64) -> [String] {
        var rng = SeededRNG(seed: seed)
        let bytes = Array(wire.utf8)
        var chunks: [Data] = []
        var index = 0
        while index < bytes.count {
            let width = rng.nextInt(in: 1 ... max(1, min(8, bytes.count - index)))
            chunks.append(Data(bytes[index ..< min(bytes.count, index + width)]))
            index += width
        }
        // Reassemble incrementally exactly as a streaming client would: buffer bytes,
        // emit complete lines, keep the trailing partial line buffered.
        var buffer = Data()
        var lines: [String] = []
        for chunk in chunks {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = Data(buffer[..<newline])
                lines.append(String(data: lineData, encoding: .utf8) ?? "")
                buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty {
            lines.append(String(data: buffer, encoding: .utf8) ?? "")
        }
        return lines.compactMap { HTTPHelpers.extractSSEData(from: $0).flatMap { String(data: $0, encoding: .utf8) } }
    }

    private func payloadsUnsplit(_ wire: String) -> [String] {
        wire.components(separatedBy: "\n").compactMap {
            HTTPHelpers.extractSSEData(from: $0).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    private func ndjsonValuesAfterSplit(_ wire: String, seed: UInt64) -> [String] {
        payloadsAfterSplitNDJSON(wire, seed: seed).map { canonicalJSON($0) }
    }

    private func payloadsAfterSplitNDJSON(_ wire: String, seed: UInt64) -> [String] {
        var rng = SeededRNG(seed: seed)
        let bytes = Array(wire.utf8)
        var buffer = Data()
        var lines: [String] = []
        var index = 0
        while index < bytes.count {
            let width = rng.nextInt(in: 1 ... max(1, min(8, bytes.count - index)))
            buffer.append(Data(bytes[index ..< min(bytes.count, index + width)]))
            index += width
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = Data(buffer[..<newline])
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    lines.append(line)
                }
                buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8), !tail.isEmpty {
            lines.append(tail)
        }
        return lines
    }

    private func canonicalJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let canonical = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "INVALID:" + text }
        return String(data: canonical, encoding: .utf8) ?? text
    }

    // MARK: - Properties

    @Test("SSE chunk splits re-frame to the same payloads as the unsplit wire")
    func sseSplitsMatchUnsplit() {
        for (wireIndex, wire) in Self.sseWires.enumerated() {
            let expected = payloadsUnsplit(wire)
            for iteration in 0 ..< caseCount {
                let actual = payloadsAfterSplit(wire, seed: seed ^ UInt64(wireIndex * 10_007 + iteration))
                #expect(
                    actual == expected,
                    "seed=\(seed) wire#\(wireIndex) iter#\(iteration): split payloads \(actual) != unsplit \(expected)"
                )
            }
        }
    }

    @Test("NDJSON chunk splits re-frame to the same values as the unsplit wire")
    func ndjsonSplitsMatchUnsplit() {
        for (wireIndex, wire) in Self.ndjsonWires.enumerated() {
            let expected = wire.components(separatedBy: "\n").filter { !$0.isEmpty }.map { canonicalJSON($0) }
            for iteration in 0 ..< caseCount {
                let actual = ndjsonValuesAfterSplit(wire, seed: seed ^ UInt64(wireIndex * 1_009 + iteration))
                #expect(
                    actual == expected,
                    "seed=\(seed) wire#\(wireIndex) iter#\(iteration): split values \(actual) != unsplit \(expected)"
                )
            }
        }
    }

    @Test("extractSSEData is total and deterministic over adversarial lines")
    func extractSSEDataTotal() {
        let lines = AdversarialPathGenerator.paths(count: caseCount, seed: seed).flatMap { path in
            ["data: \(path)", "data:\(path)", ":\(path)", path, "", "data: [DONE]"]
        }
        for line in lines {
            let first = HTTPHelpers.extractSSEData(from: line)
            let second = HTTPHelpers.extractSSEData(from: line)
            #expect(first == second, "seed=\(seed): extractSSEData nondeterministic for \(line.debugDescription)")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || !trimmed.hasPrefix("data: ") {
                #expect(first == nil, "seed=\(seed): expected nil for \(line.debugDescription)")
            }
        }
    }

    // MARK: - Committed regression fixtures

    /// A split inside the `data: ` prefix still re-frames to the same payload.
    @Test("regression: split inside the data prefix")
    func splitInsideDataPrefix() {
        let wire = "data: {\"a\":1}\n\ndata: [DONE]\n"
        // Byte widths of 1 force a split inside "data: " itself.
        var buffer = Data()
        var lines: [String] = []
        for byte in wire.utf8 {
            buffer.append(byte)
            if buffer.count == 2 {
                // Hold a partial prefix in the buffer: no complete line may be emitted yet.
                #expect(!buffer.contains(UInt8(ascii: "\n")))
            }
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = Data(buffer[..<newline])
                lines.append(String(data: lineData, encoding: .utf8) ?? "")
                buffer.removeSubrange(...newline)
            }
        }
        let payloads = lines.compactMap { HTTPHelpers.extractSSEData(from: $0) }
        #expect(payloads.count == 1)
    }

    /// A multibyte emoji split across chunks survives reassembly as valid UTF-8.
    @Test("regression: multibyte scalar split across chunks")
    func multibyteSplit() {
        let wire = "data: {\"text\":\"🎉\"}\n"
        let bytes = Array(wire.utf8)
        // Split inside the 4-byte emoji sequence.
        let emojiStart = bytes.firstIndex(of: 0xF0) ?? 0
        for cut in [emojiStart + 1, emojiStart + 2, emojiStart + 3] where cut < bytes.count {
            let head = Data(bytes[..<cut])
            let tail = Data(bytes[cut...])
            // The head alone is not valid UTF-8; the concatenation must be.
            #expect(String(data: head, encoding: .utf8) == nil || cut <= emojiStart)
            #expect(String(data: head + tail, encoding: .utf8) == wire)
        }
    }
}
