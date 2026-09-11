import Foundation
import PKContracts
import PositronicKit
import Testing

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
        #expect(provider.reference.uri == supportedReference.uri, "workspace-factory.reference.uri")
        #expect(provider.reference.location == supportedReference.location, "workspace-factory.reference.location")
        #expect(provider.reference.originID == supportedReference.originID, "workspace-factory.reference.origin")
        #expect(provider.reference.tools == supportedReference.tools, "workspace-factory.reference.tools")
        #expect(provider.reference.rootPath == supportedReference.rootPath, "workspace-factory.reference.root-path")
        #expect(provider.reference.trustLevel == supportedReference.trustLevel, "workspace-factory.reference.trust")
        #expect(provider.reference.lastModifiedBy == supportedReference.lastModifiedBy, "workspace-factory.reference.last-modified-by")
        #expect(provider.reference.status == supportedReference.status, "workspace-factory.reference.status")
        #expect(provider.reference.contextInjection == supportedReference.contextInjection, "workspace-factory.reference.context")
        #expect(provider.reference.createdAt == supportedReference.createdAt, "workspace-factory.reference.created-at")
    }

    private struct ScenarioError: Error, CustomStringConvertible {
        let id: String
        let underlying: Error

        var description: String { "\(id): \(String(describing: underlying))" }
    }
}
