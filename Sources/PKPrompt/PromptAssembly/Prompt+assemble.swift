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
    ///
    /// Returns `nil` when the assembled prompt has no renderable content (e.g. every section
    /// rendered to empty text). Structural assembly failures — duplicate section identifiers or
    /// multiple user-query sections — are not swallowed; they propagate as
    /// ``PromptAssemblyError``.
    ///
    /// - Throws: ``PromptAssemblyError`` when the concrete section graph is invalid.
    func renderToString() async throws -> String? {
        let rendered = try await assemblePrompt().render().string
        return rendered.isEmpty ? nil : rendered
    }
}
