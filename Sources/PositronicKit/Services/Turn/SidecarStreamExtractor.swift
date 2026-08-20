import Foundation
import Logging
import PartialJSON
import PKContracts
import PKUtilities

/// Incremental extractor turning raw structured-output JSON deltas into routed
/// sidecar-turn outputs. Pure value type: feed `consume(_:)` per content delta,
/// call `finish()` at stream end. Not thread-safe by design — owned and driven
/// solely by `LLMStreamingStage`'s delta loop.
struct SidecarStreamExtractor {
    enum Output: Equatable {
        /// New suffix of the user-visible `response` field.
        case responseDelta(String)
        /// Partial or final sidecar field text.
        case sidecarDelta(SidecarDelta)
        /// Terminal per-directive outcomes (emitted once, from `finish()` or object close).
        case completed([SidecarResult])
    }

    private let directives: [SidecarDirective]
    private var buffer = ""
    private var emittedResponsePrefix = ""
    private var emittedSidecarPrefixes: [String: String] = [:]
    private var finalizedFields: Set<String> = []
    private var completedEmitted = false
    /// Passthrough mode: buffer never became a JSON object — treat everything as response.
    private var passthrough = false
    private var passthroughDecided = false

    init(directives: [SidecarDirective]) {
        self.directives = directives
    }

    mutating func consume(_ delta: String) -> [Output] {
        buffer += delta

        if !passthroughDecided {
            let head = buffer.drop(while: { $0.isWhitespace })
            if head.isEmpty { return [] }
            // Decide on the first non-whitespace character: an object opener means JSON
            // mode; anything else means the model ignored the schema → passthrough.
            passthrough = head.first != "{"
            passthroughDecided = true
        }

        if passthrough {
            let out = buffer
            buffer = ""
            return out.isEmpty ? [] : [.responseDelta(out)]
        }

        return reparse()
    }

    mutating func finish() -> [Output] {
        var outputs: [Output] = []
        if passthrough {
            outputs.append(.completed(directives.map {
                SidecarResult(name: $0.name, outcome: .failed(reason: "model did not produce structured output"))
            }))
            completedEmitted = true
            return outputs
        }

        outputs += reparse()
        guard !completedEmitted else { return outputs }
        var results: [SidecarResult] = []
        let parsed = finalParse()
        for directive in directives {
            if let object = parsed, let payload = payload(for: directive, from: object) {
                if payload[directive.name] is NSNull {
                    results.append(SidecarResult(name: directive.name, outcome: .declined))
                    continue
                }
                if finalizedFields.contains(directive.name), let value = payload[directive.name] {
                    results.append(SidecarResult(name: directive.name, outcome: .value(AnyCodable(value))))
                    continue
                }
                if payload[directive.name] != nil {
                    results.append(SidecarResult(
                        name: directive.name,
                        outcome: .failed(reason: "field incomplete at stream end")
                    ))
                    continue
                }
            }
            results.append(SidecarResult(name: directive.name, outcome: .failed(reason: "field missing at stream end")))
        }
        completedEmitted = true
        outputs.append(.completed(results))
        return outputs
    }

    // MARK: - Parsing

    /// Best-effort parse of the whole buffer via PartialJSON (partial strings allowed).
    private func currentParse() -> [String: Any]? {
        (try? PartialJSON.parse(buffer, options: .all)) as? [String: Any]
    }

    private func finalParse() -> [String: Any]? {
        if let parsed = currentParse() {
            return parsed
        }

        guard let repaired = try? LenientJSONParser.parse(buffer),
              repaired.repaired,
              let object = repaired.value.value as? [String: Any]
        else {
            return nil
        }

        Logger.module(named: "sidecar-stream-extractor")
            .warning("Recovered sidecar payload via lenient JSON repair at stream end.")
        return object
    }

    private func sidecarPayload(from object: [String: Any]) -> [String: Any]? {
        object[RootKey.sidecarPayload] as? [String: Any]
    }

    private func priorityPayload(from object: [String: Any]) -> [String: Any]? {
        object[RootKey.prioritySidecarPayload] as? [String: Any]
    }

    private mutating func reparse() -> [Output] {
        guard let object = currentParse() else { return [] }
        var outputs: [Output] = []
        let closed = objectClosed()

        // 1. Priority sidecars may precede the first response delta in the same chunk.
        outputs += collectDirectiveOutputs(
            for: directives.filter { $0.timing == .beforeResponse },
            in: object,
            closed: closed,
            containerBoundaryReached: rawKeyPresent(RootKey.response) || rawKeyPresent(RootKey.sidecarPayload)
        )

        // 2. response suffix
        if let response = object[RootKey.response] as? String,
           response.hasPrefix(emittedResponsePrefix), response.count > emittedResponsePrefix.count
        {
            let suffix = String(response.dropFirst(emittedResponsePrefix.count))
            emittedResponsePrefix = response
            outputs.append(.responseDelta(suffix))
        }

        // 3. Post-response sidecars complete when a later sibling appears or the object closes.
        outputs += collectDirectiveOutputs(
            for: directives.filter { $0.timing == .afterResponse },
            in: object,
            closed: closed,
            containerBoundaryReached: closed
        )
        return outputs
    }

    private mutating func collectDirectiveOutputs(
        for directives: [SidecarDirective],
        in object: [String: Any],
        closed: Bool,
        containerBoundaryReached: Bool
    ) -> [Output] {
        var outputs: [Output] = []
        for (index, directive) in directives.enumerated() {
            guard !finalizedFields.contains(directive.name) else { continue }
            guard let payload = payload(for: directive, from: object), payload[directive.name] != nil else { continue }

            if payload[directive.name] is NSNull {
                if closed || laterKeyStarted(after: index, in: directives) || containerBoundaryReached {
                    finalizedFields.insert(directive.name)
                }
                continue // declines surface only in `completed` results
            }

            let text = stringRepresentation(payload[directive.name])
            let previous = emittedSidecarPrefixes[directive.name] ?? ""
            let isFinal = closed || laterKeyStarted(after: index, in: directives) || containerBoundaryReached

            if isFinal {
                finalizedFields.insert(directive.name)
                outputs.append(.sidecarDelta(SidecarDelta(name: directive.name, partialText: text, isFinal: true)))
                emittedSidecarPrefixes[directive.name] = text
            } else if directive.streaming == .incremental, text != previous {
                outputs.append(.sidecarDelta(SidecarDelta(name: directive.name, partialText: text, isFinal: false)))
                emittedSidecarPrefixes[directive.name] = text
            }
        }
        return outputs
    }

    /// True when the top-level object's braces are balanced in the raw buffer
    /// (string-aware scan; quotes and escapes respected).
    private func objectClosed() -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        var seenOpen = false
        for char in buffer {
            if escaped { escaped = false; continue }
            switch char {
            case "\\" where inString: escaped = true
            case "\"": inString.toggle()
            case "{" where !inString: depth += 1; seenOpen = true
            case "}" where !inString: depth -= 1
            default: break
            }
        }
        return seenOpen && depth == 0
    }

    /// True when any key that would come after `index` (directive order) has appeared
    /// in the raw buffer as `"name"`.
    private func laterKeyStarted(after index: Int, in directives: [SidecarDirective]) -> Bool {
        let laterNames = directives.suffix(from: directives.index(after: index)).map(\.name)
        return laterNames.contains { rawKeyPresent($0) }
    }

    private func payload(for directive: SidecarDirective, from object: [String: Any]) -> [String: Any]? {
        switch directive.timing {
        case .beforeResponse:
            return priorityPayload(from: object)
        case .afterResponse:
            return sidecarPayload(from: object) ?? object
        }
    }

    private func rawKeyPresent(_ name: String) -> Bool {
        buffer.contains("\"\(name)\"")
    }

    private func stringRepresentation(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let some?:
            if let data = try? JSONSerialization.data(withJSONObject: some, options: [.fragmentsAllowed]) {
                return String(decoding: data, as: UTF8.self)
            }
            return String(describing: some)
        case nil: return ""
        }
    }

    private typealias RootKey = SidecarDirective.RootKey
}
