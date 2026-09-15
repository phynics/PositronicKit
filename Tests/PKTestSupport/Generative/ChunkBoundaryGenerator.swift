import Foundation

/// Deterministic chunk-boundary and truncation generation for streaming surfaces.
///
/// Covers the issue #155 property: an arbitrary chunk-boundary split of a valid stream
/// must decode to the same result as the unsplit stream. Splits are computed over
/// `String` character offsets (never inside a multi-byte scalar in a way that breaks
/// `String` itself — offsets are clamped to valid indices), so every split is a faithful
/// re-framing of the same bytes a provider could emit.
public enum ChunkBoundaryGenerator {
    /// Split `text` into `chunkCount` non-empty chunks at seeded cut points.
    public static func split(_ text: String, chunkCount: Int, rng: inout SeededRNG) -> [String] {
        precondition(chunkCount >= 1, "chunkCount must be positive")
        guard !text.isEmpty, chunkCount > 1 else { return [text] }
        let scalars = Array(text.unicodeScalars)
        var cuts = Set<Int>()
        while cuts.count < min(chunkCount - 1, scalars.count - 1) {
            cuts.insert(rng.nextInt(in: 1 ..< scalars.count))
        }
        let ordered = cuts.sorted()
        var chunks: [String] = []
        var previous = 0
        for cut in ordered + [scalars.count] {
            chunks.append(String(String.UnicodeScalarView(scalars[previous ..< cut])))
            previous = cut
        }
        return chunks
    }

    /// Generate `count` independent seeded splittings of `text` (1..8 chunks each).
    public static func splittings(of text: String, count: Int, seed: UInt64) -> [[String]] {
        var rng = SeededRNG(seed: seed)
        return (0 ..< count).map { _ in
            let chunks = rng.nextInt(in: 1 ..< 9)
            return split(text, chunkCount: chunks, rng: &rng)
        }
    }

    /// Every byte-offset truncation of `payload` (for small corpora), or a seeded sample
    /// of `sampleCount` offsets for larger payloads. Truncation at offset `i` keeps the
    /// first `i` bytes; invalid-UTF8 prefixes are skipped so every case is a real string.
    public static func truncations(of payload: String, sampleCount: Int = GenerativeConfig.defaultCaseCount, seed: UInt64 = GenerativeConfig.defaultSeed) -> [String] {
        let bytes = Array(payload.utf8)
        if bytes.count <= 256 {
            return (0 ... bytes.count).compactMap { offset in
                String(bytes: bytes.prefix(offset), encoding: .utf8)
            }
        }
        var rng = SeededRNG(seed: seed)
        var offsets = Set<Int>([0, bytes.count])
        while offsets.count < min(sampleCount, bytes.count + 1) {
            offsets.insert(rng.nextInt(in: 0 ... bytes.count))
        }
        return offsets.sorted().compactMap { offset in
            String(bytes: bytes.prefix(offset), encoding: .utf8)
        }
    }
}

/// Deterministic adversarial path generation complementing the example-based jail tests.
///
/// Draws from traversal (`..`), sibling-prefix (`jail-evil` vs `jail`), absolute paths,
/// tilde expansion, empty/dot segments, repeated separators, unicode, and overlong inputs.
/// Every value is a plain string — the property under test is that `PathSanitizer`
/// either resolves inside the jail or throws, deterministically.
public enum AdversarialPathGenerator {
    static let fragments = [
        "..", ".", "", "a", "evil", "jail-evil", "subdir", "file.txt",
        "a b", "a#b", "a?b", "~", "~/x", "/etc/passwd", "/tmp/jail",
        "..\\..", "…", "é", "a\u{0}b",
        String(repeating: "a", count: 64),
        String(repeating: "../", count: 4),
    ]

    static let separators = ["/", "//", "/./", "/../"]

    /// Generate `count` adversarial relative/absolute path strings from `seed`.
    public static func paths(count: Int, seed: UInt64) -> [String] {
        var rng = SeededRNG(seed: seed)
        return (0 ..< count).map { _ in
            let parts = rng.nextInt(in: 1 ..< 5)
            var path = (0 ..< parts).map { _ in rng.nextElement(fragments) }.joined(separator: rng.nextElement(separators))
            switch rng.nextInt(upperBound: 4) {
            case 0: path = "/" + path
            case 1: path = "~/" + path
            default: break
            }
            return path
        }
    }
}
