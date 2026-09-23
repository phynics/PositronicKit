import PKContracts

extension LLMStreamChunk {
    /// A chunk carrying one choice at index 0, the shape every non-OpenAI-family adapter emits.
    package init(
        id: String,
        model: String,
        delta: LLMStreamDelta,
        finishReason: String? = nil,
        usage: LLMTokenUsage? = nil
    ) {
        self.init(
            id: id,
            model: model,
            choices: [LLMStreamChoice(index: 0, delta: delta, finishReason: finishReason)],
            usage: usage
        )
    }
}
