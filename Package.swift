// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MaxMailCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MaxMailCore", targets: ["MaxMailCore"]),
        .executable(name: "maxmail-stress", targets: ["MaxMailStress"]),
    ],
    targets: [
        .target(
            name: "MaxMailCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "MaxMailStress",
            dependencies: ["MaxMailCore"]
        ),
        .testTarget(
            name: "MaxMailCoreTests",
            dependencies: ["MaxMailCore"]
        ),
    ]
)
