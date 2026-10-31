// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Maser",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Maser", targets: ["Maser"]),
    ],
    targets: [
        .target(name: "MaserCore"),
        .executableTarget(
            name: "Maser",
            dependencies: ["MaserCore"]
        ),
        .testTarget(
            name: "MaserCoreTests",
            dependencies: ["MaserCore"]
        ),
    ]
)
