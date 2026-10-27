// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iPorts",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "iPorts", targets: ["iPorts"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(
            name: "PortsCore", path: "src/PortsCore",
            resources: [.copy("Resources/ModelArtwork"), .copy("Resources/MacCatalog.json")]),
        .executableTarget(
            name: "iPorts",
            dependencies: ["PortsCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "src/iPorts",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]),
        .testTarget(name: "PortsCoreTests", dependencies: ["PortsCore"], path: "tests/PortsCoreTests"),
        .testTarget(name: "iPortsTests", dependencies: ["iPorts", "PortsCore"], path: "tests/iPortsTests"),
    ]
)
