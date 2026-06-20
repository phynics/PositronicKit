// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PKFastEmbed",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "PKFastEmbed", targets: ["PKFastEmbed"]),
    ],
    targets: [
        .systemLibrary(
            name: "CPKFastEmbed",
            pkgConfig: "pkfastembed"
        ),
        .target(
            name: "PKFastEmbed",
            dependencies: ["CPKFastEmbed"]
        ),
        .testTarget(
            name: "PKFastEmbedTests",
            dependencies: ["PKFastEmbed"]
        ),
    ]
)
