import Testing

/// Test-layer tags for the `PKAgentFiles` adapter target (see docs/Testing.md).
///
/// Tags cannot live in `PKTestSupport`: that module deliberately uses `internal import Testing`
/// so the toolchain module never leaks into its public interface, while tags must be public to
/// their consumers. Keep this definition in sync with the runtime and provider targets.
extension Tag {
    /// Fast, deterministic single-type contracts.
    @Tag static var unit: Self
    /// Multi-component adapter behavior over the runtime.
    @Tag static var integration: Self
    /// Long-running stress and concurrency suites.
    @Tag static var slow: Self
    /// Behavior that differs by platform.
    @Tag static var platformSpecific: Self
    /// Bounded, seeded generative/property suites.
    @Tag static var generative: Self
}
