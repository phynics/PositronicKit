// swift-tools-version: 6.1
import Foundation
import PackageDescription

let pkfastembedLibDir: String = {
    let prefix = ProcessInfo.processInfo.environment["PKFASTEMBED_PREFIX"]
        ?? "\(FileManager.default.currentDirectoryPath)/.build/pkfastembed"
    return "\(prefix)/lib"
}()

let package = Package(
    name: "PositronicKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "PositronicKit", targets: ["PositronicKit"]),
        .library(name: "PKPrompt", targets: ["PKPrompt"]),
        .library(name: "PKShared", targets: ["PKShared"]),
        .library(name: "PKLocalEmbeddings", targets: ["PKLocalEmbeddings"]),
        .library(name: "PKOpenAIProvider", targets: ["PKOpenAIProvider"]),
        .library(name: "PKOpenRouterProvider", targets: ["PKOpenRouterProvider"]),
        .library(name: "PKOllamaProvider", targets: ["PKOllamaProvider"]),
        .library(name: "PKTestSupport", targets: ["PKTestSupport"]),
        .executable(name: "PositronicKitExamples", targets: ["PositronicKitExamples"]),
    ],
    traits: [
        .trait(
            name: "MiniLMEmbeddings",
            description: "Build the in-process MiniLM embedding backend on Apple platforms."
        ),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.4.8"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/FlineDev/ErrorKit", from: "1.0.0"),
        .package(url: "https://github.com/ajevans99/swift-json-schema", exact: "0.11.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
        .package(url: "https://github.com/itruf/PartialJSON.git", exact: "0.0.2"),
    ],
    targets: [
        .target(
            name: "PKShared",
            dependencies: [
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
                .product(name: "PartialJSON", package: "PartialJSON"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/PKShared"
        ),
        .target(
            name: "PKPrompt",
            dependencies: ["PKShared"],
            path: "Sources/PKPrompt"
        ),
        .target(
            name: "PositronicKit",
            dependencies: [
                "PKShared",
                "PKPrompt",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
                .product(name: "PartialJSON", package: "PartialJSON"),
            ],
            path: "Sources/PositronicKit",
            exclude: ["README.md"]
        ),
        .target(
            name: "PKLocalEmbeddings",
            dependencies: [
                "PositronicKit",
                "PKShared",
                .product(name: "Crypto", package: "swift-crypto"),
                .target(name: "PKFastEmbed", condition: .when(platforms: [.linux])),
                .target(name: "PKFastEmbed", condition: .when(traits: ["MiniLMEmbeddings"])),
            ],
            path: "Sources/PKLocalEmbeddings"
        ),
        .systemLibrary(
            name: "CPKFastEmbed",
            path: "Sources/CPKFastEmbed",
            pkgConfig: "pkfastembed"
        ),
        .target(
            name: "PKFastEmbed",
            dependencies: ["CPKFastEmbed", "PKShared", "PositronicKit"],
            path: "Sources/PKFastEmbed",
            linkerSettings: [
                .unsafeFlags(["-L\(pkfastembedLibDir)"], .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "PKOpenAIProvider",
            dependencies: [
                "PositronicKit",
                "PKPrompt",
                "PKShared",
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOpenAIProvider"
        ),
        .target(
            name: "PKOpenRouterProvider",
            dependencies: [
                "PositronicKit",
                "PKShared",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOpenRouterProvider"
        ),
        .target(
            name: "PKOllamaProvider",
            dependencies: [
                "PositronicKit",
                "PKShared",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/PKOllamaProvider"
        ),
        .executableTarget(
            name: "PositronicKitExamples",
            dependencies: [
                "PositronicKit",
                "PKLocalEmbeddings",
                "PKOpenAIProvider",
                "PKOpenRouterProvider",
                "PKOllamaProvider",
                "PKPrompt",
                "PKShared",
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Sources/PositronicKitExamples"
        ),
        .target(
            name: "PKTestSupport",
            dependencies: [
                "PositronicKit",
                "PKShared",
                "PKPrompt",
                .product(name: "JSONSchema", package: "swift-json-schema"),
            ],
            path: "Tests/PKTestSupport"
        ),
        .testTarget(
            name: "PositronicKitTests",
            dependencies: [
                "PositronicKit",
                "PKLocalEmbeddings",
                "PKOpenAIProvider",
                "PKOpenRouterProvider",
                "PKOllamaProvider",
                "PositronicKitExamples",
                "PKShared",
                "PKTestSupport",
            ],
            path: "Tests/PositronicKitTests"
        ),
        .testTarget(
            name: "PKLocalEmbeddingsTests",
            dependencies: [
                "PKLocalEmbeddings",
                "PositronicKit",
                "PKShared",
                "PKTestSupport",
            ],
            path: "Tests/PKLocalEmbeddingsTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PKFastEmbedTests",
            dependencies: [
                .target(name: "PKFastEmbed", condition: .when(traits: ["MiniLMEmbeddings"])),
            ],
            path: "Tests/PKFastEmbedTests"
        ),
        .testTarget(
            name: "PKPromptTests",
            dependencies: ["PKPrompt", "PKShared", "PKTestSupport"],
            path: "Tests/PKPromptTests"
        ),
        .testTarget(
            name: "PKSharedTests",
            dependencies: [
                "PKShared",
                "PKTestSupport",
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
            ],
            path: "Tests/PKSharedTests"
        ),
        .testTarget(
            name: "PKTestSupportTests",
            dependencies: [
                "PKTestSupport",
                "PKShared",
            ],
            path: "Tests/PKTestSupportTests"
        ),
    ]
)
