// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Backgrounds",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Backgrounds", targets: ["Backgrounds"]),
    ],
    targets: [
        .target(name: "BackgroundsCore", path: "Sources/BackgroundsCore"),
        .executableTarget(
            name: "Backgrounds",
            dependencies: ["BackgroundsCore"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "BackgroundsTests",
            dependencies: ["BackgroundsCore"],
            path: "Tests/BackgroundsTests"
        ),
    ]
)
