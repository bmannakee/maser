// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Maser",
    platforms: [.macOS(.v27)],
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
