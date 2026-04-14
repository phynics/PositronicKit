/// A generic result builder for constructing pipelines from stages.
@resultBuilder
public struct PipelineBuilder<Context: Sendable, Event: Sendable> {
    public static func buildBlock(
        _ components: [any PipelineStage<Context, Event>]...
    ) -> [any PipelineStage<Context, Event>] {
        components.flatMap { $0 }
    }

    public static func buildExpression(
        _ expression: any PipelineStage<Context, Event>
    ) -> [any PipelineStage<Context, Event>] {
        [expression]
    }

    public static func buildOptional(
        _ component: [any PipelineStage<Context, Event>]?
    ) -> [any PipelineStage<Context, Event>] {
        component ?? []
    }

    public static func buildEither(
        first component: [any PipelineStage<Context, Event>]
    ) -> [any PipelineStage<Context, Event>] {
        component
    }

    public static func buildEither(
        second component: [any PipelineStage<Context, Event>]
    ) -> [any PipelineStage<Context, Event>] {
        component
    }

    public static func buildArray(
        _ components: [[any PipelineStage<Context, Event>]]
    ) -> [any PipelineStage<Context, Event>] {
        components.flatMap { $0 }
    }
}

public extension Pipeline {
    /// Initializes a pipeline using a result builder DSL.
    /// - Parameter builder: A closure returning the stages of the pipeline.
    convenience init(
        @PipelineBuilder<Context, Event> stages builder: () -> [any PipelineStage<Context, Event>]
    ) {
        self.init(stages: builder())
    }
}
