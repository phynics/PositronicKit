import Foundation
import PKUtilities

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
    let identity = StableHash.hash(components: [typeName, String(describing: prompt.id)])
    return "\(typeName) \(identity)"
}
