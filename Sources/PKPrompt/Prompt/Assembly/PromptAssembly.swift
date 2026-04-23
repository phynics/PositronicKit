//
//  PromptResolutionContext.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 18.04.26.
//


package enum PromptAssembly {
    package static func resolve(
        _ prompt: some Prompt,
        in context: Context = Context()
    ) -> [AssembledPrompt.Section] {
        if prompt is EmptyPrompt {
            return []
        }

        if let prompt = prompt as? any PromptPrimitive {
            return prompt.assembleSections(in: context)
        }

        if let prompt = prompt as? any PromptAssemblyNode {
            return prompt.assembleSections(in: context)
        }

        return resolve(
            prompt.body,
            in: context.descending(into: String(describing: type(of: prompt)))
        )
    }

    package struct Context: Sendable {
        package let ancestorPath: [String]
        package let inheritedPriority: Int?
        package let inheritedCompression: CompressionStrategy?
        package let inheritedCachePolicy: CachePolicy?

        package init(
            ancestorPath: [String] = ["prompt"],
            inheritedPriority: Int? = nil,
            inheritedCompression: CompressionStrategy? = nil,
            inheritedCachePolicy: CachePolicy? = nil
        ) {
            self.ancestorPath = ancestorPath
            self.inheritedPriority = inheritedPriority
            self.inheritedCompression = inheritedCompression
            self.inheritedCachePolicy = inheritedCachePolicy
        }

        package func descending(into component: String?) -> Context {
            guard let component, !component.isEmpty else {
                return self
            }

            var path = ancestorPath
            path.append(component)
            return Context(
                ancestorPath: path,
                inheritedPriority: inheritedPriority,
                inheritedCompression: inheritedCompression,
                inheritedCachePolicy: inheritedCachePolicy
            )
        }

        package func applying(
            priority: Int? = nil,
            compression: CompressionStrategy? = nil,
            cachePolicy: CachePolicy? = nil
        ) -> Context {
            Context(
                ancestorPath: ancestorPath,
                inheritedPriority: priority ?? inheritedPriority,
                inheritedCompression: compression ?? inheritedCompression,
                inheritedCachePolicy: cachePolicy ?? inheritedCachePolicy
            )
        }
    }
}
