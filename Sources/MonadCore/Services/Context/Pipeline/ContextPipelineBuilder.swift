import MonadPrompt
import MonadShared

/// A result builder for constructing context gathering pipelines.
public typealias ContextPipelineBuilder = PipelineBuilder<ContextPipelineContext, ContextGatheringEvent>

/// Convenience typealias for context gathering pipelines.
public typealias ContextPipeline = Pipeline<ContextPipelineContext, ContextGatheringEvent>
