// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ChessSimilarity",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ChessSimilarity", targets: ["ChessSimilarity"]),
        .executable(name: "chess-similarity-tool", targets: ["chess-similarity-tool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/NSStudent/fischer-core.git", from: "0.4.0"),
        .package(url: "https://github.com/NSStudent/ChessPawnStructures.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "ChessSimilarity",
            dependencies: [
                .product(name: "FischerCore", package: "fischer-core"),
                .product(name: "ChessPawnStructures", package: "ChessPawnStructures"),
            ]
        ),
        .executableTarget(
            name: "chess-similarity-tool",
            dependencies: [
                "ChessSimilarity",
                .product(name: "FischerCore", package: "fischer-core"),
            ],
            // A measuring script with top-level state; strict concurrency adds nothing here.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChessSimilarityTests",
            dependencies: ["ChessSimilarity"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
