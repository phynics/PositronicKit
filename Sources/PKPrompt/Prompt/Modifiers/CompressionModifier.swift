//
//  CompressionModifier.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 14.04.26.
//


import Foundation
import PKShared

public extension Prompt {
    func compression(_ value: CompressionStrategy) -> some Prompt {
        CompressionModifier(content: self, compression: value)
    }
}

public struct CompressionModifier<Content: Prompt>: Prompt {
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
