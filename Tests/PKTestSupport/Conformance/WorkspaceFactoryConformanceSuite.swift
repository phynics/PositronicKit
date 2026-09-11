import Foundation
import PKContracts
import PositronicKit
internal import Testing

/// Runs the documented successful-creation check for a ``WorkspaceFactory``.
public enum WorkspaceFactoryConformanceSuite {
    /// Creates a provider for a caller-supplied supported reference and verifies that the
    /// provider preserves the complete reference.
    public static func run(
        factory: any WorkspaceFactory,
        supportedReference: WorkspaceReference
    ) throws {
        let provider: any WorkspaceProvider
        do {
            provider = try factory.create(from: supportedReference)
        } catch {
            throw ScenarioError(id: "workspace-factory.create", underlying: error)
        }
        try #require(provider.reference.id == supportedReference.id, "workspace-factory.reference.id")
        try #require(provider.reference.uri == supportedReference.uri, "workspace-factory.reference.uri")
        try #require(provider.reference.location == supportedReference.location, "workspace-factory.reference.location")
        try #require(provider.reference.originID == supportedReference.originID, "workspace-factory.reference.origin")
        try #require(provider.reference.tools == supportedReference.tools, "workspace-factory.reference.tools")
        try #require(provider.reference.rootPath == supportedReference.rootPath, "workspace-factory.reference.root-path")
        try #require(provider.reference.trustLevel == supportedReference.trustLevel, "workspace-factory.reference.trust")
        try #require(provider.reference.lastModifiedBy == supportedReference.lastModifiedBy, "workspace-factory.reference.last-modified-by")
        try #require(provider.reference.status == supportedReference.status, "workspace-factory.reference.status")
        try #require(provider.reference.contextInjection == supportedReference.contextInjection, "workspace-factory.reference.context")
        try #require(provider.reference.createdAt == supportedReference.createdAt, "workspace-factory.reference.created-at")
    }

    private struct ScenarioError: Error, CustomStringConvertible {
        let id: String
        let underlying: Error

        var description: String { "\(id): \(String(describing: underlying))" }
    }
}
