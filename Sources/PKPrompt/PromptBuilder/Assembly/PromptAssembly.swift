//
//  PromptResolutionContext.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 18.04.26.
//


package enum PromptAssembly {
    package static func makeNode(from prompt: some Prompt) -> PromptNode? {
        if prompt is EmptyPrompt {
            return nil
        }

        if let prompt = prompt as? any PromptNodeConvertible {
            return prompt.makePromptNode()?.normalized()
        }

        guard let bodyNode = makeNode(from: prompt.body) else {
            return nil
        }

        return PromptNode(
            pathComponent: String(describing: type(of: prompt)),
            children: [bodyNode]
        )
    }

    package static func resolve(
        _ prompt: some Prompt,
        in context: Context = Context()
    ) -> [AssembledPrompt.Section] {
        makeNode(from: prompt)?.resolve(in: context) ?? []
    }

    package struct Context: Sendable {
        package let ancestorPath: [String]
        package let inheritedTraits: PromptTraits

        package init(
            ancestorPath: [String] = ["prompt"],
            inheritedTraits: PromptTraits = PromptTraits()
        ) {
            self.ancestorPath = ancestorPath
            self.inheritedTraits = inheritedTraits
        }

        package func descending(into component: String?) -> Context {
            guard let component, !component.isEmpty else {
                return self
            }

            var path = ancestorPath
            path.append(component)
            return Context(
                ancestorPath: path,
                inheritedTraits: inheritedTraits
            )
        }

        package func applying(_ traits: PromptTraits) -> Context {
            Context(
                ancestorPath: ancestorPath,
                inheritedTraits: inheritedTraits.applying(
                    priority: traits.priority,
                    compression: traits.compression,
                    cachePolicy: traits.cachePolicy
                )
            )
        }
    }
}
