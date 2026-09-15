import Foundation

/// Committed regression corpus for generative suites (issue #155).
///
/// A discovered counterexample is committed here as a fixture — not left to be
/// rediscovered by the next seeded run. Each entry records the seed/case that found it
/// and the invariant it guards. Suites assert these cases explicitly in addition to the
/// seeded random exploration.
public enum GenerativeRegressionCorpus {
    /// Streaming inputs where chunk boundaries once mattered: think tags, code fences,
    /// orphaned closers, and pipe-delimited markers split across chunks.
    public static let streamingDocuments = [
        "<think>reasoning</think>answer",
        "before <think>inner ```code``` still thinking</think> after",
        "Some content that was actually thinking </think> Real content",
        "```\n<think>\n```",
        "Start <|tool_call_begin|> middle <|tool_call_end|> end",
        "<thi" + "nk>split tag</think>",
        "{\"tool\": \"call\", \"args\": {\"city\": \"Berlin\"}}",
    ]

    /// Valid JSON documents truncated at every byte offset by the PartialJSON property suite.
    public static let jsonDocuments = [
        #"{"city":"Berlin"}"#,
        #"{"name":"lookup_weather","arguments":{"city":"Berlin","units":"metric"}}"#,
        #"{"items":[1,2,3],"nested":{"a":true,"b":null}}"#,
        #"{"text":"hello \"world\"","emoji":"🎉"}"#,
    ]

    /// Adversarial paths that must stay inside the jail or throw. Includes the classic
    /// sibling-prefix trap (`<jail>-evil` shares a string prefix with `<jail>` but is
    /// outside it) and tilde/absolute escape attempts.
    public static let adversarialPaths = [
        "..",
        "../..",
        "../../etc/passwd",
        "/etc/passwd",
        "~/",
        ".",
        "",
        "subdir/../../..",
        "jail-evil",
        "../<jail>-sibling",
        "a/b/../../../../c",
        String(repeating: "a", count: 256),
    ]
}
