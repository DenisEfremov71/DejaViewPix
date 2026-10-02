// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AlbumAI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AlbumAI", targets: ["AlbumAI"]),
        // `swift run evals`: scores the search against evals/cases.json. Costs money.
        .executable(name: "evals", targets: ["evals"]),
    ],
    targets: [
        .target(name: "AlbumAI", resources: [.process("Resources")]),
        // Dataset, scoring, canned library and report: everything but the command line,
        // so the scoring rules have offline tests.
        .target(name: "EvalKit", dependencies: ["AlbumAI"]),
        .executableTarget(name: "evals", dependencies: ["EvalKit", "AlbumAI"]),
        .testTarget(name: "AlbumAITests", dependencies: ["AlbumAI"]),
        .testTarget(name: "EvalKitTests", dependencies: ["EvalKit", "AlbumAI"]),
    ]
)
