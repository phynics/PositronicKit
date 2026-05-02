import Foundation

/// Base protocol for declarative prompt composition.
public protocol Prompt<Body>: Sendable {
    associatedtype Body: Prompt
    var body: Body { get }
    func makePromptNode() -> PromptNode?
}
