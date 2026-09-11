import Foundation
import PKContracts
import PositronicKit
internal import Testing

/// Runs the documented CRUD checks for a ``RequestOriginStoreProtocol`` implementation.
public enum RequestOriginStoreConformanceSuite {
    /// Runs the request-origin checks against an isolated store for every scenario.
    public static func run(
        makeStore: () async throws -> any RequestOriginStoreProtocol
    ) async throws {
        try await runScenario("origin.empty") {
            try await emptyStoreReads(makeStore: makeStore)
        }
        try await runScenario("origin.save.fetch") {
            try await savesAndFetches(makeStore: makeStore)
        }
        try await runScenario("origin.replace") {
            try await replacesByID(makeStore: makeStore)
        }
        try await runScenario("origin.fetch-all") {
            try await fetchesAllOrigins(makeStore: makeStore)
        }
        try await runScenario("origin.delete") {
            try await deletesOneOrigin(makeStore: makeStore)
        }
    }

    private struct ScenarioError: Error, CustomStringConvertible {
        let id: String
        let underlying: Error

        var description: String { "\(id): \(String(describing: underlying))" }
    }

    private static func runScenario(
        _ id: String,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            if error is Testing.ExpectationFailedError {
                throw error
            }
            throw ScenarioError(id: id, underlying: error)
        }
    }

    private static func emptyStoreReads(
        makeStore: () async throws -> any RequestOriginStoreProtocol
    ) async throws {
        let store = try await makeStore()
        try #require(try await store.fetchOrigin(id: UUID()) == nil, "origin.empty.fetch")
        try #require(try await store.fetchAllOrigins().isEmpty, "origin.empty.all")
    }

    private static func savesAndFetches(
        makeStore: () async throws -> any RequestOriginStoreProtocol
    ) async throws {
        let store = try await makeStore()
        let origin = makeOrigin()
        try await store.saveOrigin(origin)
        try expectEquivalent(
            try #require(try await store.fetchOrigin(id: origin.id), "origin.save.fetch.value"),
            origin,
            scenario: "origin.save.fetch"
        )
    }

    private static func replacesByID(
        makeStore: () async throws -> any RequestOriginStoreProtocol
    ) async throws {
        let store = try await makeStore()
        let id = UUID()
        try await store.saveOrigin(makeOrigin(id: id, displayName: "Original"))
        try await store.saveOrigin(makeOrigin(id: id, displayName: "Updated"))

        try #require(try await store.fetchOrigin(id: id)?.displayName == "Updated", "origin.replace.value")
        try #require(try await store.fetchAllOrigins().count == 1, "origin.replace.unique-id")
    }

    private static func fetchesAllOrigins(
        makeStore: () async throws -> any RequestOriginStoreProtocol
    ) async throws {
        let store = try await makeStore()
        let origins = [makeOrigin(), makeOrigin(), makeOrigin()]
        for origin in origins {
            try await store.saveOrigin(origin)
        }

        let fetched = try await store.fetchAllOrigins()
        try #require(
            fetched.count == origins.count && Set(fetched.map(\.id)) == Set(origins.map(\.id)),
            "origin.fetch-all.membership"
        )
    }

    private static func deletesOneOrigin(
        makeStore: () async throws -> any RequestOriginStoreProtocol
    ) async throws {
        let store = try await makeStore()
        let keep = makeOrigin()
        let remove = makeOrigin()
        try await store.saveOrigin(keep)
        try await store.saveOrigin(remove)

        try #require(try await store.deleteOrigin(id: remove.id), "origin.delete.existing")
        try #require(try await store.fetchOrigin(id: remove.id) == nil, "origin.delete.removes-target")
        try expectEquivalent(
            try #require(try await store.fetchOrigin(id: keep.id), "origin.delete.preserves-other.value"),
            keep,
            scenario: "origin.delete.preserves-other"
        )
        try #require(try await store.deleteOrigin(id: UUID()) == false, "origin.delete.unknown")
    }

    private static func makeOrigin(
        id: UUID = UUID(),
        displayName: String = "Example"
    ) -> RequestOriginIdentity {
        RequestOriginIdentity(
            id: id,
            hostname: "host.example",
            displayName: displayName,
            platform: "linux"
        )
    }

    private static func expectEquivalent(
        _ actual: RequestOriginIdentity,
        _ expected: RequestOriginIdentity,
        scenario: String
    ) throws {
        try #require(actual.id == expected.id, "\(scenario).id")
        try #require(actual.hostname == expected.hostname, "\(scenario).hostname")
        try #require(actual.displayName == expected.displayName, "\(scenario).display-name")
        try #require(actual.platform == expected.platform, "\(scenario).platform")
        try #require(actual.registeredAt == expected.registeredAt, "\(scenario).registered-at")
        try #require(actual.lastSeenAt == expected.lastSeenAt, "\(scenario).last-seen")
    }
}
