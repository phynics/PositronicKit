import PKContracts
import PositronicKit
public import Testing

// Swift Testing's `CustomTestReflectable` conformances for the large public domain
// values that the suite compares in `#expect`. Failure output then shows the fields
// that identify the value instead of recursively expanding every stored property.
//
// They belong to test support rather than the runtime: the runtime must not depend on
// Swift Testing, and custom reflection only has meaning while a test presents a value.
// The protocol appears in PKTestSupport's public interface, so this file imports
// `Testing` as `public` rather than the `internal import` the conformance suites use.

extension Message: CustomTestReflectable {
    /// A compact mirror: identity, role, content, and status, without the full
    /// content-part list, tool calls, and timestamp.
    public var customTestMirror: Mirror {
        Mirror(self, children: [
            (label: "id", value: id),
            (label: "role", value: role.rawValue),
            (label: "content", value: content),
            (label: "status", value: status?.rawValue as Any),
            (label: "reasoning", value: reasoning as Any),
            (label: "toolCalls", value: toolCalls?.map(\.name) as Any),
        ])
    }
}

extension TurnEvent: CustomTestReflectable {
    /// A compact mirror: the event category and a single-line rendering of its payload.
    public var customTestMirror: Mirror {
        switch self {
        case let .delta(event):
            Mirror(self, children: [(label: "delta", value: String(describing: event))])
        case let .error(event):
            Mirror(self, children: [(label: "error", value: String(describing: event))])
        case let .completion(event):
            Mirror(self, children: [(label: "completion", value: String(describing: event))])
        }
    }
}

extension TurnOutcome: CustomTestReflectable {
    /// A compact mirror: the terminal case and its diagnostic, when present.
    public var customTestMirror: Mirror {
        switch self {
        case .completed:
            Mirror(self, children: [(label: "completed", value: true)])
        case let .failed(message):
            Mirror(self, children: [(label: "failed", value: message)])
        case let .cancelled(reason):
            Mirror(self, children: [(label: "cancelled", value: reason as Any)])
        case let .interrupted(reason):
            Mirror(self, children: [(label: "interrupted", value: reason)])
        }
    }
}
