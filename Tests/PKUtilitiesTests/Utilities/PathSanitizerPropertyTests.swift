import Foundation
import Testing

@testable import PKUtilities
import PKTestSupport

/// Generative coverage for `PathSanitizer` over adversarial path inputs (issue #155),
/// complementing the example-based jail tests.
///
/// Property: for every generated path, `safelyResolve` either throws `PathError` or
/// returns a URL contained in the jail root — never an escaped path — and identical
/// input resolves identically (deterministic). Bounded (`defaultCaseCount` cases) and
/// deterministic under a fixed seed (`PK_GENERATIVE_SEED` overrides; failures report
/// the seed).
@Suite("PathSanitizer generative property", .tags(.generative))
struct PathSanitizerPropertyTests {
    private let seed = GenerativeConfig.effectiveSeed()
    private let caseCount = GenerativeConfig.defaultCaseCount

    private func makeJail() throws -> (root: String, current: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pk-generative-jail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root.path, root.path)
    }

    private func isWithinJail(_ candidate: URL, root: String) -> Bool {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let candidateURL = candidate.standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let candidateComponents = candidateURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }

    @Test("generated paths resolve inside the jail or throw")
    func adversarialPathsStayJailed() throws {
        let jail = try makeJail()
        defer { try? FileManager.default.removeItem(atPath: jail.root) }
        let paths = AdversarialPathGenerator.paths(count: caseCount, seed: seed)
            + GenerativeRegressionCorpus.adversarialPaths
        for (index, path) in paths.enumerated() {
            do {
                let resolved = try PathSanitizer.safelyResolve(path: path, within: jail.current, jailRoot: jail.root)
                #expect(
                    isWithinJail(resolved, root: jail.root),
                    "seed=\(seed) path#\(index) \(path.debugDescription): resolved outside jail to \(resolved.path)"
                )
                // Determinism: identical input, identical output.
                let again = try PathSanitizer.safelyResolve(path: path, within: jail.current, jailRoot: jail.root)
                #expect(
                    again == resolved,
                    "seed=\(seed) path#\(index) \(path.debugDescription): nondeterministic resolution"
                )
            } catch let error as PathSanitizer.PathError {
                // Throwing is the other legal outcome; no further assertion needed.
                _ = error
            } catch {
                Issue.record("seed=\(seed) path#\(index) \(path.debugDescription): unexpected error \(error)")
            }
        }
    }

    @Test("sibling-prefix paths are rejected even though they share a string prefix")
    func siblingPrefixRejected() throws {
        let jail = try makeJail()
        defer { try? FileManager.default.removeItem(atPath: jail.root) }
        // `<jail>-evil` starts with the jail string but is a different directory.
        let sibling = jail.root + "-evil"
        #expect(throws: PathSanitizer.PathError.self) {
            try PathSanitizer.safelyResolve(path: sibling, within: jail.current, jailRoot: jail.root)
        }
        #expect(throws: PathSanitizer.PathError.self) {
            try PathSanitizer.safelyResolve(path: "../\(URL(fileURLWithPath: jail.root).lastPathComponent)-evil", within: jail.current, jailRoot: jail.root)
        }
    }

    // MARK: - Committed regression fixtures

    /// Absolute escapes and parent traversal throw rather than resolve outside.
    @Test("regression: absolute and traversal escapes throw")
    func absoluteAndTraversalThrow() throws {
        let jail = try makeJail()
        defer { try? FileManager.default.removeItem(atPath: jail.root) }
        for path in ["/etc/passwd", "..", "../..", "../../etc/passwd", "subdir/../../.."] {
            #expect(throws: PathSanitizer.PathError.self) {
                try PathSanitizer.safelyResolve(path: path, within: jail.current, jailRoot: jail.root)
            }
        }
    }

    /// Tilde expansion cannot escape the jail.
    @Test("regression: tilde paths stay jailed or throw")
    func tildeStaysJailed() throws {
        let jail = try makeJail()
        defer { try? FileManager.default.removeItem(atPath: jail.root) }
        for path in ["~", "~/x", "~root"] {
            do {
                let resolved = try PathSanitizer.safelyResolve(path: path, within: jail.current, jailRoot: jail.root)
                #expect(isWithinJail(resolved, root: jail.root), "\(path.debugDescription) escaped to \(resolved.path)")
            } catch is PathSanitizer.PathError {
                // Legal: refused.
            }
        }
    }
}
