//
//  Prompt+makeNode.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 30.04.26.
//


package extension Prompt {
    func makeNode() -> PromptNode? {
        if self is EmptyPrompt {
            return nil
        }

        if let prompt = self as? any PromptNodeConvertible {
            return prompt.makePromptNode()
        }

        guard let bodyNode = self.body.makeNode() else {
            return nil
        }

        return PromptNode(
            pathComponent: String(describing: type(of: self)),
            .fork([bodyNode])
        )
    }
}

package extension Prompt {
    func resolveSections(in context: PromptResolutionContext = PromptResolutionContext()) -> [PromptSection] {
        makeNode()?.resolve(in: context) ?? []
    }
}
