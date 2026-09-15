import Foundation
import Testing

/// The `.generative` tag for bounded, seeded property suites in this target.
///
/// Canonical taxonomy lives in `PositronicKitTests/Support/TestTags.swift` and
/// `PKProviderIntegrationTests/Support/TestTags.swift` (see docs/Testing.md); tags cannot
/// live in `PKTestSupport` because that module uses `internal import Testing`. Module
/// targets define only `.generative` so their property suites stay off the fast loop
/// (`Scripts/generate-test-fast-filter.py` excludes `.tags(.generative)` files wholesale).
extension Tag {
    /// Bounded, seeded generative/property suites. Excluded from the fast loop and the
    /// default gate's critical path; run explicitly or on the nightly flake-detection job.
    @Tag static var generative: Self
}
