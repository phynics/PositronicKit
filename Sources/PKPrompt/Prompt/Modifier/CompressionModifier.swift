//
//  CompressionModifier.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 14.04.26.
//


import Foundation
import PKShared

public extension PromptComposite {
    func compression(_ value: CompressionStrategy) -> some PromptComposite {
        CompressionModifier(content: self, compression: value)
    }
}

public struct CompressionModifier<Content: PromptComposite>: PromptComposite {
    let content: Content
    let compression: CompressionStrategy

    public var body: NeverSection {
        NeverSection()
    }

    public var sectionPathComponent: String? {
        nil
    }

    public func resolve(in context: PromptResolutionContext) -> [ResolvedPromptSection] {
        content.resolve(in: context.applying(compression: compression))
    }
}
