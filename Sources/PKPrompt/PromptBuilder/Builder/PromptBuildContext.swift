import Foundation

/// Resolution-time context carried while lowering prompt nodes into concrete sections.
package struct PromptBuildContext: Sendable {
    /// Canonical ancestor path accumulated from enclosing prompt structure.
    package let ancestorPath: [String]

    /// Traits inherited from enclosing prompt nodes.
    package let inheritedTraits: PromptTraits

    package init(
        ancestorPath: [String] = ["prompt"],
        inheritedTraits: PromptTraits = PromptTraits()
    ) {
        self.ancestorPath = ancestorPath
        self.inheritedTraits = inheritedTraits
    }

    package func descending(into component: String?) -> PromptBuildContext {
        guard let component, !component.isEmpty else {
            return self
        }

        var path = ancestorPath
        path.append(component)
        return PromptBuildContext(
            ancestorPath: path,
            inheritedTraits: inheritedTraits
        )
    }

    package func applying(_ traits: PromptTraits) -> PromptBuildContext {
        PromptBuildContext(
            ancestorPath: ancestorPath,
            inheritedTraits: inheritedTraits.applying(
                priority: traits.priority,
                compression: traits.compression,
                cachePolicy: traits.cachePolicy
            )
        )
    }
}
