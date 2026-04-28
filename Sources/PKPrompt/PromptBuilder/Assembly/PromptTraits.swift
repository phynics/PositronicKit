//
//  PromptTraits.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 29.04.26.
//


package struct PromptTraits: Sendable {
    package let priority: Int?
    package let compression: CompressionStrategy?
    package let cachePolicy: CachePolicy?

    package init(
        priority: Int? = nil,
        compression: CompressionStrategy? = nil,
        cachePolicy: CachePolicy? = nil
    ) {
        self.priority = priority
        self.compression = compression
        self.cachePolicy = cachePolicy
    }

    package var isEmpty: Bool {
        priority == nil && compression == nil && cachePolicy == nil
    }

    package func applying(
        priority: Int? = nil,
        compression: CompressionStrategy? = nil,
        cachePolicy: CachePolicy? = nil
    ) -> PromptTraits {
        PromptTraits(
            priority: priority ?? self.priority,
            compression: compression ?? self.compression,
            cachePolicy: cachePolicy ?? self.cachePolicy
        )
    }
}