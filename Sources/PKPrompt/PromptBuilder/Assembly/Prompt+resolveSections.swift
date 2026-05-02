//
//  Prompt+makeNode.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 30.04.26.
//

package extension Prompt {
    func resolveSections(in context: PromptResolutionContext = PromptResolutionContext()) -> [PromptSection] {
        makePromptNode()?.resolve(in: context) ?? []
    }
}
