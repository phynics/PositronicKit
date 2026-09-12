import PositronicKit

actor TestTurnOutcomeRecorder: TurnOutcomeSink {
    private var records: [TurnOutcomeRecord] = []

    func record(_ outcome: TurnOutcomeRecord) async throws {
        records.append(outcome)
    }

    func lastRecord() -> TurnOutcomeRecord? {
        records.last
    }
}
