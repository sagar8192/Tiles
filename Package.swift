// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tiles",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Tiles", targets: ["Tiles"])
    ],
    targets: [
        .executableTarget(
            name: "Tiles",
            path: "Sources/Tiles"
        ),
        .testTarget(
            name: "TilesTests",
            dependencies: ["Tiles"],
            path: "Tests/TilesTests"
        )
    ]
)
