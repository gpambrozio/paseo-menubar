// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PaseoIconPackage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PaseoIconCore", targets: ["PaseoIconCore"]),
        .executable(name: "PaseoIcon", targets: ["PaseoIcon"]),
        .executable(name: "PaseoIconProbe", targets: ["PaseoIconProbe"]),
    ],
    dependencies: [
        // Pinned exactly: the E2EE wire format is libsodium's crypto_box, and the
        // xcframework this ships is a static archive, so signing needs no extra step.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0"),
        // TestClock, so timers (hello retry, connect timeout, ping, backoff) are
        // tested deterministically instead of with real sleeps.
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.4"),
    ],
    targets: [
        .target(
            name: "PaseoIconCore",
            dependencies: [.product(name: "Sodium", package: "swift-sodium")]
        ),
        .executableTarget(
            name: "PaseoIcon",
            dependencies: ["PaseoIconCore"],
            // The same PNGs `npm run icons` rasterizes for the Electron build,
            // so both apps show the same marks. Generated, not committed.
            resources: [.copy("Resources/TrayIcons")]
        ),
        .executableTarget(name: "PaseoIconProbe", dependencies: ["PaseoIconCore"]),
        .testTarget(
            name: "PaseoIconCoreTests",
            dependencies: [
                "PaseoIconCore",
                .product(name: "Clocks", package: "swift-clocks"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
