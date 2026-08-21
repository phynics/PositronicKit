import Foundation
import XCTest

enum MiniLMTestSupport {
    static func goldenVectorPrefix() throws -> [Float] {
        let data = try Data(contentsOf: Bundle.module.url(
            forResource: "minilm-golden",
            withExtension: "json"
        )!)
        return try JSONDecoder().decode([Float].self, from: data)
    }

    static func requireModelDirectory(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PK_MINILM_MODEL_DIR"], !path.isEmpty else {
            throw XCTSkip("Set PK_MINILM_MODEL_DIR to the pinned all-MiniLM-L6-v2 asset directory.")
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("PK_MINILM_MODEL_DIR does not point to a readable directory.")
        }
        return directory
    }

    static func makeScratchCopy(of sourceDirectory: URL) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pklocalembeddings-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for fileName in [
            "config.json",
            "model.onnx",
            "special_tokens_map.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "vocab.txt",
        ] {
            try FileManager.default.copyItem(
                at: sourceDirectory.appendingPathComponent(fileName),
                to: root.appendingPathComponent(fileName)
            )
        }

        return root
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dotProduct: Float = 0
        var lhsMagnitude: Float = 0
        var rhsMagnitude: Float = 0

        for (left, right) in zip(lhs, rhs) {
            dotProduct += left * right
            lhsMagnitude += left * left
            rhsMagnitude += right * right
        }

        return dotProduct / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }

    static func l2Norm(_ vector: [Float]) -> Float {
        sqrt(vector.reduce(0) { $0 + ($1 * $1) })
    }
}
