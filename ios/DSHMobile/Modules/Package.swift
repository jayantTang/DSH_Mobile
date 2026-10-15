// swift-tools-version: 5.9
//
// DSHMobile 模块包（025 模块化重构）
//
// 分层（依赖只允许向下）：
//   L1 功能单元：DSH<X>UI → DSH<X>Domain；横切 DSHDesign
//   L2 核心服务：DSHCore；纯协议 DSHConnectionAPI
//   L4 基础：DSHFoundation
//   L3 协议层 DSHKit/RelayKit 是独立包（ios/DSHMobile/DSHKit），本包按本地路径依赖它
//
// DSHTestingSupport 仅供 *Tests 依赖，产品 target 不得依赖它。
//
// 边界由 scripts/dev/check-module-boundaries.mjs 做文本级复核；
// 例外登记在 BOUNDARY-EXCEPTIONS.md。

import PackageDescription

let dshKit: Target.Dependency = .product(name: "DSHKit", package: "DSHKit")

let package = Package(
    name: "DSHMobileModules",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DSHFoundation", targets: ["DSHFoundation"]),
        .library(name: "DSHDesign", targets: ["DSHDesign"]),
        .library(name: "DSHCore", targets: ["DSHCore"]),
        .library(name: "DSHConnectionAPI", targets: ["DSHConnectionAPI"]),
        .library(name: "DSHTestingSupport", targets: ["DSHTestingSupport"]),
    ],
    dependencies: [
        .package(path: "../DSHKit"),
    ],
    targets: [
        // L4 基础层：零业务、零 UI
        .target(name: "DSHFoundation"),
        .testTarget(name: "DSHFoundationTests", dependencies: ["DSHFoundation"]),

        // L1 横切设计系统：仅 SwiftUI
        .target(name: "DSHDesign", dependencies: ["DSHFoundation"]),

        // L2 纯协议：连接服务接口
        .target(name: "DSHConnectionAPI"),

        // L2 核心服务：事件分发 / 传输编排 / 路由意图（禁 UI）
        .target(name: "DSHCore", dependencies: ["DSHConnectionAPI", "DSHFoundation", dshKit]),
        .testTarget(name: "DSHCoreTests", dependencies: ["DSHCore", "DSHTestingSupport"]),

        // 测试辅助：仅测试依赖
        .target(name: "DSHTestingSupport", dependencies: ["DSHCore", "DSHConnectionAPI", dshKit]),
    ]
)
