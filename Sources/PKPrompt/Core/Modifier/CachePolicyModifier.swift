//
//  CachePolicyModifier.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 14.04.26.
//


import Foundation
import PKShared

public extension PromptComposite {
    func cachePolicy(_ value: CachePolicy) -> some PromptComposite {
        CachePolicyModifier(content: self, cachePolicy: value)
    }
}

public struct CachePolicyModifier<Content: PromptComposite>: PromptComposite {
    let content: Content
    let cachePolicy: CachePolicy

    public var body: NeverSection {
        NeverSection()
    }

    public var sectionPathComponent: String? {
        nil
    }

    public func resolve(in context: PromptResolutionContext) -> [ResolvedPromptSection] {
        content.resolve(in: context.applying(cachePolicy: cachePolicy))
    }
}
