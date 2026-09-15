import Testing

/// Test-layer tags for this target's taxonomy (see docs/Testing.md).
///
/// The same five tags are defined in `PKProviderIntegrationTests/Support/TestTags.swift`.
/// Tags cannot live in `PKTestSupport`: that module deliberately uses `internal import Testing`
/// so the toolchain module never leaks into its public interface, while tags must be public to
/// their consumers. Keep the two definitions in sync. Suites opt in with
/// `@Suite(..., .tags(.unit))`; `make test-fast` selects the `.unit` subset.
extension Tag {
    /// Fast, deterministic single-type contracts. Selected by `make test-fast`.
    @Tag static var unit: Self
    /// Multi-component runtime behavior: Turns, Timelines, Workspaces, stores, stories, providers, and examples.
    @Tag static var integration: Self
    /// Long-running stress and concurrency suites. Excluded from the fast loop.
    @Tag static var slow: Self
    /// Behavior that differs by platform, such as conditional FoundationNetworking imports.
    @Tag static var platformSpecific: Self
    /// Bounded, seeded generative/property suites. Excluded from the fast loop and the
    /// default gate's critical path; run explicitly or on the nightly flake-detection job.
    @Tag static var generative: Self
}
