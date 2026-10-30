// swift-tools-version: 5.10
import PackageDescription
import Foundation

let cltTestingPlugin = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingPlugin)
    ? [.unsafeFlags(["-load-plugin-library", cltTestingPlugin])]
    : []

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
            path: "Tests/TilesTests",
            swiftSettings: testSwiftSettings
        )
    ]
)
