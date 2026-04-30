//
//  PriorityModifier.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 14.04.26.
//


import Foundation
import PKShared

public extension Prompt {
    func priority(_ value: Int) -> some Prompt {
        PromptModifiers.Priority(content: self, priority: value)
    }

    func priority(_ value: PromptPriority) -> some Prompt {
        PromptModifiers.Priority(content: self, priority: value.rawValue)
    }

    func compression(_ value: CompressionStrategy) -> some Prompt {
        PromptModifiers.Compression(content: self, compression: value)
    }

    func cachePolicy(_ value: CachePolicy) -> some Prompt {
        PromptModifiers.CachePolicy(content: self, cachePolicy: value)
    }
}

package enum PromptModifiers {
    package struct Priority<Content: Prompt>: Prompt {
        package let content: Content
        package let priority: Int

        package var body: EmptyPrompt { EmptyPrompt() }

        package func makePromptNode() -> PromptNode? {
            guard let child = content.makeNode() else {
                return nil
            }
            return PromptNode(traits: PromptTraits(priority: priority), .fork([child]))
        }
    }

    package struct Compression<Content: Prompt>: Prompt {
        package let content: Content
        package let compression: CompressionStrategy

        package var body: EmptyPrompt { EmptyPrompt() }

        package func makePromptNode() -> PromptNode? {
            guard let child = content.makeNode() else {
                return nil
            }
            return PromptNode(traits: PromptTraits(compression: compression), .fork([child]))
        }
    }

    package struct CachePolicy<Content: Prompt>: Prompt {
        package let content: Content
        package let cachePolicy: PKPrompt.CachePolicy

        package var body: EmptyPrompt { EmptyPrompt() }

        package func makePromptNode() -> PromptNode? {
            guard let child = content.makeNode() else {
                return nil
            }
            return PromptNode(traits: PromptTraits(cachePolicy: cachePolicy), .fork([child]))
        }
    }
}
