import Foundation

/// Deprecated shared compatibility declarations for the v3 timeline spelling.
public extension PKErrorDomain {
    /// The historical timeline error domain. Its value is unchanged for persisted and logged
    /// error identities.
    @available(*, deprecated, message: "Timeline APIs are deprecated and will be removed in v4. Use the corresponding Thread API instead.")
    static var timeline: String { thread }
}
