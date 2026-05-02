//
//  PromptModifiers.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 14.04.26.
//

import Foundation
import PKShared

package enum PromptModifiers {
    package struct Priority<Content: Prompt>: Prompt {
        package let content: Content
        package let priority: Int

        package var body: EmptyPrompt { EmptyPrompt() }

        package func makePromptNode() -> PromptNode? {
            guard let child = content.makePromptNode() else {
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
            guard let child = content.makePromptNode() else {
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
            guard let child = content.makePromptNode() else {
                return nil
            }
            return PromptNode(traits: PromptTraits(cachePolicy: cachePolicy), .fork([child]))
        }
    }
}
