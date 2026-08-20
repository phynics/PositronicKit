import Crypto
import Foundation
import PKContracts

package enum MiniLMModelAssets {
    package static let revision = "5f1b8cd78bc4fb444dd171e59b18f3a3af89a079"

    package static let requiredFiles: [String: String] = [
        "config.json": "1b4d8e2a3988377ed8b519a31d8d31025a25f1c5f8606998e8014111438efcd7",
        "model.onnx": "bbd7b466f6d58e646fdc2bd5fd67b2f5e93c0b687011bd4548c420f7bd46f0c5",
        "special_tokens_map.json": "5d5b662e421ea9fac075174bb0688ee0d9431699900b90662acd44b2a350503a",
        "tokenizer.json": "da0e79933b9ed51798a3ae27893d3c5fa4a201126cef75586296df9b4d2c62a0",
        "tokenizer_config.json": "bd2e06a5b20fd1b13ca988bedc8763d332d242381b4fbc98f8fead4524158f79",
        "vocab.txt": "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3",
    ]

    package static func validate(modelDirectory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EmbeddingError.modelDirectoryMissing
        }

        for (fileName, expectedChecksum) in requiredFiles {
            let fileURL = modelDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw EmbeddingError.modelFilesMissing
            }

            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard checksum == expectedChecksum else {
                throw EmbeddingError.modelChecksumMismatch
            }
        }
    }
}
