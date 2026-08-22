import PKContracts

struct AgentActivityFanout: AgentActivitySink {
    let sinks: [any AgentActivitySink]

    func record(_ activity: AgentActivity) async throws {
        for sink in sinks {
            try await sink.record(activity)
        }
    }
}
