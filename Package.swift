// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Maser",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Maser", targets: ["Maser"]),
        .executable(name: "maser-trace", targets: ["maser-trace"]),
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
        // Traceability checking for docs/design/; a development tool, not part of the app.
        .target(name: "Traceability"),
        .executableTarget(
            name: "maser-trace",
            dependencies: ["Traceability"]
        ),
        .testTarget(
            name: "TraceabilityTests",
            dependencies: ["Traceability"]
        ),
        // A stand-in for gh that replays recorded responses, for scripts/check-ui; not part of the app.
        .executableTarget(name: "fake-gh"),
    ]
)
