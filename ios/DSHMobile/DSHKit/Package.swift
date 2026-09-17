// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DSHKit", targets: ["DSHKit"]),
    ],
    targets: [
        .target(
            name: "DSHKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DSHKitTests",
            dependencies: ["DSHKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
