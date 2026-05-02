import Foundation

public extension Prompt {
    func makePromptNode() -> PromptNode? {
        guard let bodyNode = self.body.makePromptNode() else {
            return nil
        }

        return PromptNode(
            pathComponent: promptPathComponent(for: self),
            .fork([bodyNode])
        )
    }
}

private func promptPathComponent<P: Prompt>(for prompt: P) -> String {
    let typeName = String(describing: type(of: prompt))
    guard let prompt = prompt as? any Identifiable else {
        return typeName
    }
    return "\(typeName) \(prompt.id.hashValue)"
}
