// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PositronicKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "PositronicKit", targets: ["PositronicKit"]),
        .library(name: "PKPrompt", targets: ["PKPrompt"]),
        .library(name: "PKShared", targets: ["PKShared"]),
        .library(name: "PKTestSupport", targets: ["PKTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.4.8"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
        .package(url: "https://github.com/FlineDev/ErrorKit", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "PKShared",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "ErrorKit", package: "ErrorKit"),
                .product(name: "Logging", package: "swift-log"),
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
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "ErrorKit", package: "ErrorKit"),
            ],
            path: "Sources/PositronicKit",
            exclude: ["README.md", "docs"]
        ),
        .target(
            name: "PKTestSupport",
            dependencies: [
                "PositronicKit",
                "PKShared",
                "PKPrompt",
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            path: "Tests/PKTestSupport"
        ),
        .testTarget(
            name: "PositronicKitTests",
            dependencies: [
                "PositronicKit",
                "PKShared",
                "PKTestSupport",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            path: "Tests/PositronicKitTests"
        ),
        .testTarget(
            name: "PKPromptTests",
            dependencies: ["PKPrompt", "PKTestSupport"],
            path: "Tests/PKPromptTests"
        ),
        .testTarget(
            name: "PKSharedTests",
            dependencies: ["PKShared", "PKTestSupport"],
            path: "Tests/PKSharedTests"
        ),
    ]
)
