import Foundation
import Testing

@testable import PKContracts
import PKTestSupport

/// Truncation property for `LenientJSONParser` recovery (issue #155).
///
/// Property: for every byte-offset truncation of a valid JSON document, parsing either
/// throws `invalidJSONPayload` or returns a value that (a) re-encodes to valid JSON and
/// (b) agrees with strict parsing about whether repair happened (`wasRepaired == false`
/// exactly when the truncation is already strict-valid). Parsing is deterministic: the
/// same input always yields the same result. Bounded (exhaustive offsets for small
/// documents, seeded samples beyond) and deterministic under a fixed seed.
@Suite("LenientJSON truncation property", .tags(.generative))
struct LenientJSONTruncationPropertyTests {
    private let seed = GenerativeConfig.effectiveSeed()

    private func isStrictValid(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private func reencodes(_ value: AnyCodable) -> Bool {
        guard let data = try? LenientJSONParser.jsonData(from: value) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    @Test("every truncation either throws or repairs to re-encodable JSON")
    func truncationsThrowOrRepair() throws {
        for (docIndex, document) in GenerativeRegressionCorpus.jsonDocuments.enumerated() {
            // The whole document is strict-valid: no repair flag.
            let whole = try LenientJSONParser.parse(document)
            #expect(!whole.wasRepaired, "seed=\(seed) doc#\(docIndex): valid JSON must not report repair")

            for truncation in ChunkBoundaryGenerator.truncations(of: document, seed: seed ^ UInt64(docIndex)) {
                let strict = isStrictValid(truncation)
                do {
                    let result = try LenientJSONParser.parse(truncation)
                    #expect(
                        result.wasRepaired != strict,
                        "seed=\(seed) doc#\(docIndex) offset trunc=\(truncation.debugDescription): wasRepaired=\(result.wasRepaired) but strictValid=\(strict)"
                    )
                    #expect(
                        reencodes(result.value),
                        "seed=\(seed) doc#\(docIndex) trunc=\(truncation.debugDescription): repaired value does not re-encode"
                    )
                    // Determinism: same input, same outcome.
                    let again = try LenientJSONParser.parse(truncation)
                    #expect(
                        again == result,
                        "seed=\(seed) doc#\(docIndex) trunc=\(truncation.debugDescription): nondeterministic parse"
                    )
                } catch {
                    // Only the empty truncation and unrecoverable prefixes may throw; any
                    // throw must be the typed payload error, never a crash.
                    #expect(
                        error is LenientJSONParsingError,
                        "seed=\(seed) doc#\(docIndex) trunc=\(truncation.debugDescription): unexpected error \(error)"
                    )
                }
            }
        }
    }

    @Test("empty and whitespace-only inputs always throw")
    func emptyThrows() {
        for input in ["", "   ", "\n\t "] {
            #expect(throws: LenientJSONParsingError.self) {
                try LenientJSONParser.parse(input)
            }
        }
    }

    // MARK: - Committed regression fixtures

    /// A truncation mid-string (`{"city":"Ber`) repairs without throwing and re-encodes.
    @Test("regression: mid-string truncation repairs")
    func midStringTruncation() throws {
        let truncation = #"{"city":"Ber"#
        let result = try LenientJSONParser.parse(truncation)
        #expect(result.wasRepaired)
        let data = try LenientJSONParser.jsonData(from: result.value)
        #expect((try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil)
    }

    /// A truncation mid-escape stays total: it throws the typed error or repairs, never traps.
    @Test("regression: truncation inside an escape sequence")
    func escapeTruncation() {
        let truncation = #"{"text":"hello \"wo"#
        do {
            let result = try LenientJSONParser.parse(truncation)
            #expect(result.wasRepaired)
        } catch {
            #expect(error is LenientJSONParsingError)
        }
    }
}
