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
    dependencies: [
        // 009 磁盘层（specs/009-message-pipeline research D1，owner 已批准引入）：
        // GRDB 提供 WAL、类型安全查询与 FTS5 封装，取代 007 的手写 SQLite 层。
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
    ],
    targets: [
        .target(
            name: "DSHKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
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
            // `Fixtures/` 是真实服务端响应的原文（E3），用例用 `#filePath` 读它；
            // 它不是要编译/拷贝进 bundle 的源，声明成 exclude 让 SwiftPM 不再报
            // "unhandled file" 警告。
            exclude: ["Fixtures"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
