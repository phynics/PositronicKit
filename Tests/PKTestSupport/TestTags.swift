import Testing

/// Canonical test-layer tags for the PositronicKit test taxonomy.
///
/// The tags are defined once in PKTestSupport so every test target shares the
/// same vocabulary (see docs/Testing.md). Suites opt in with
/// `@Suite(..., .tags(.unit))`; `make test-fast` selects the `.unit` subset
/// for the inner loop while the full gates always run every suite, including
/// untagged legacy XCTest classes which cannot carry swift-testing tags.
extension Tag {
    /// Fast, deterministic single-type contracts. Selected by `make test-fast`.
    @Tag public static var unit: Self
    /// Multi-component runtime behavior: Turns, Threads, Workspaces, stores,
    /// stories, providers, and examples.
    @Tag public static var integration: Self
    /// Long-running stress and concurrency suites. Excluded from the fast loop.
    @Tag public static var slow: Self
    /// Behavior that differs by platform (for example conditional
    /// FoundationNetworking imports on Linux versus Darwin).
    @Tag public static var platformSpecific: Self
}
