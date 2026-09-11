import Foundation

/// Package-only access to the capability manifest used by executable provider tests.
package enum ProviderCapabilityMatrixManifest {
    package struct PublishedRow: Codable, Sendable, Equatable {
        package let `provider`: String
        package let imageInput: String
        package let audioInput: String
        package let audioOutput: String
        package let layoutNotes: String

        private enum CodingKeys: String, CodingKey {
            case provider = "Provider"
            case imageInput = "Image input"
            case audioInput = "Audio input"
            case audioOutput = "Audio output"
            case layoutNotes = "Layout notes"
        }
    }

    package struct Published: Codable, Sendable, Equatable {
        package let headers: [String]
        package let rows: [PublishedRow]
    }

    package struct Case: Codable, Sendable, Equatable {
        package let id: String
        package let provider: String
        package let capability: String
        package let expected: String
        package let representation: String
        package let expectedError: String?
        package let probe: String
    }

    package struct Document: Codable, Sendable, Equatable {
        package let schemaVersion: Int
        package let published: Published
        package let cases: [Case]
    }

    package static func load() throws -> Document {
        guard let url = Bundle.module.url(forResource: "ProviderCapabilityMatrix", withExtension: "json") else {
            throw MatrixError.missingResource
        }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
    }

    package enum MatrixError: Error, Sendable, Equatable {
        case missingResource
    }
}
