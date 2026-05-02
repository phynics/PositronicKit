//
//  Prompt+assemble.swift
//  PositronicKit
//
//  Created by Atakan Dulker on 02.05.26.
//

public extension Prompt {
    /// Assembles this declarative prompt tree into a validated, ordered prompt artifact.
    ///
    /// - Throws: ``AssembledPrompt/ValidationError`` when the concrete section graph is invalid.
    func assemblePrompt() throws -> AssembledPrompt {
        try AssembledPrompt(sections: resolveSections(in: .init()))
    }
    
    /// Renders this prompt into its canonical plain-text representation.
    func renderToString() async -> String? {
        guard let rendered = try? await assemblePrompt().render().string else {
            return nil
        }
        return rendered.isEmpty ? nil : rendered
    }
}
