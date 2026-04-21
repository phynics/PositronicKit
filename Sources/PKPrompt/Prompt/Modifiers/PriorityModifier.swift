//
//  PriorityModifier.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 14.04.26.
//


import Foundation
import PKShared

public enum PromptPriority: Int, Sendable {
    case low = 25
    case medium = 50
    case high = 75
    case critical = 100
}

public extension Prompt {
    func priority(_ value: Int) -> some Prompt {
        PriorityModifier(content: self, priority: value)
    }

    func priority(_ value: PromptPriority) -> some Prompt {
        priority(value.rawValue)
    }
}

public struct PriorityModifier<Content: Prompt>: Prompt {
    let content: Content
    let priority: Int

    public var body: NeverSection {
        NeverSection()
    }

    public var sectionPathComponent: String? {
        nil
    }

    public func resolve(in context: PromptResolutionContext) -> [ConcretePromptSection] {
        content.resolve(in: context.applying(priority: priority))
    }
}
