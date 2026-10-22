// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RoundsCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RoundsCore", targets: ["RoundsCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "RoundsCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "RoundsCoreTests",
            dependencies: ["RoundsCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
