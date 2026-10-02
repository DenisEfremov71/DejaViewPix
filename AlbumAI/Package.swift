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
    ],
    targets: [
        .target(name: "AlbumAI"),
    ]
)
