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

        return makePromptNode()
    }
}

package extension Prompt {
    func resolveSections(in context: PromptResolutionContext = PromptResolutionContext()) -> [PromptSection] {
        makeNode()?.resolve(in: context) ?? []
    }
}
