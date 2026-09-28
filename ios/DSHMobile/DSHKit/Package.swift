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
        // 中转侧的设备管理单独成模块：它是 relay 的 HTTP 客户端，不是 DLP 协议的一部分
        // （见 Sources/RelayKit/RelayDevices.swift 的头注）。
        // 依赖方向只有一条：RelayKit → DSHKit，反过来会成环。
        .library(name: "RelayKit", targets: ["RelayKit"]),
    ],
    targets: [
        .target(
            name: "DSHKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "RelayKit",
            dependencies: ["DSHKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DSHKitTests",
            // 同时依赖两者：RelayDeviceAdminTests 测的是 RelayKit 的类型，
            // 但它与 DLP 契约测试共用一个测试目标，这样测试文件不用搬家。
            dependencies: ["DSHKit", "RelayKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
