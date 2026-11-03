// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Maser",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Maser", targets: ["Maser"])
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5")
    ],
    targets: [
        .target(
            name: "MaserCore",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]
        ),
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
