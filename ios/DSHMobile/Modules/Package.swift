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
let relayKit: Target.Dependency = .product(name: "RelayKit", package: "DSHKit")

let package = Package(
    name: "DSHMobileModules",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DSHFoundation", targets: ["DSHFoundation"]),
        .library(name: "DSHDesign", targets: ["DSHDesign"]),
        .library(name: "DSHCore", targets: ["DSHCore"]),
        .library(name: "DSHConnectionAPI", targets: ["DSHConnectionAPI"]),
        .library(name: "DSHConnectionDomain", targets: ["DSHConnectionDomain"]),
        .library(name: "DSHConnectionUI", targets: ["DSHConnectionUI"]),
        .library(name: "DSHSessionsDomain", targets: ["DSHSessionsDomain"]),
        .library(name: "DSHSessionsUI", targets: ["DSHSessionsUI"]),
        .library(name: "DSHChatDomain", targets: ["DSHChatDomain"]),
        .library(name: "DSHChatUI", targets: ["DSHChatUI"]),
        .library(name: "DSHSettingsDomain", targets: ["DSHSettingsDomain"]),
        .library(name: "DSHSettingsUI", targets: ["DSHSettingsUI"]),
        .library(name: "DSHFeedbackDomain", targets: ["DSHFeedbackDomain"]),
        .library(name: "DSHFeedbackUI", targets: ["DSHFeedbackUI"]),
        .library(name: "DSHPluginUI", targets: ["DSHPluginUI"]),
        .library(name: "DSHFilesDomain", targets: ["DSHFilesDomain"]),
        .library(name: "DSHFilesUI", targets: ["DSHFilesUI"]),
        .library(name: "DSHTestingSupport", targets: ["DSHTestingSupport"]),
    ],
    dependencies: [
        .package(path: "../DSHKit"),
        // 快照测试：Design 组件回归（固定 size class/主题/locale，防假阳性）
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.17.0"),
    ],
    targets: [
        // L4 基础层：零业务、零 UI
        .target(name: "DSHFoundation"),
        .testTarget(name: "DSHFoundationTests", dependencies: ["DSHFoundation"]),

        // L1 横切设计系统：仅 SwiftUI
        .target(name: "DSHDesign", dependencies: ["DSHFoundation"]),
        .testTarget(name: "DSHDesignTests", dependencies: [
            "DSHDesign",
            .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
        ]),

        // L2 纯协议：连接服务接口
        .target(name: "DSHConnectionAPI", dependencies: [dshKit]),

        // L2 核心服务：事件分发 / 传输编排 / 路由意图（禁 UI）
        .target(name: "DSHCore", dependencies: ["DSHConnectionAPI", "DSHFoundation", dshKit, relayKit]),
        .testTarget(name: "DSHCoreTests", dependencies: [
            "DSHCore", "DSHTestingSupport", dshKit,
        ]),

        // L1 连接单元领域层：实现 LinkService（禁 UI）
        .target(name: "DSHConnectionDomain", dependencies: ["DSHConnectionAPI", "DSHFoundation", dshKit, relayKit]),
        .testTarget(name: "DSHConnectionDomainTests", dependencies: [
            "DSHConnectionDomain", "DSHConnectionAPI", "DSHTestingSupport", dshKit, relayKit,
        ]),

        // L1 连接单元界面层
        .target(name: "DSHConnectionUI", dependencies: ["DSHConnectionDomain", "DSHDesign", "DSHCore"]),

        // L1 会话单元
        .target(name: "DSHSessionsDomain", dependencies: ["DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit]),
        .target(name: "DSHSessionsUI", dependencies: ["DSHSessionsDomain", "DSHDesign", "DSHCore"]),

        // L1 聊天单元：转写/流式/分页的领域层，与转写界面层
        .target(name: "DSHChatDomain", dependencies: ["DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit]),
        // 传输注入缝用例要 FakeLinkService + FakeCarrier（026 的 clientOverride），
        // 并直接点名 HostEventHub / ConnectionProfile。
        .testTarget(name: "DSHChatDomainTests", dependencies: [
            "DSHChatDomain", "DSHTestingSupport", "DSHCore", "DSHConnectionAPI", dshKit,
        ]),
        .target(name: "DSHChatUI", dependencies: ["DSHChatDomain", "DSHDesign", "DSHCore"]),

        // L1 设置单元
        .target(name: "DSHSettingsDomain", dependencies: ["DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit, relayKit]),
        .target(name: "DSHSettingsUI", dependencies: ["DSHSettingsDomain", "DSHDesign", "DSHCore", "DSHConnectionDomain"]),

        // L1 信箱单元
        .target(name: "DSHFeedbackDomain", dependencies: ["DSHFoundation", dshKit, relayKit]),
        .target(name: "DSHFeedbackUI", dependencies: ["DSHFeedbackDomain", "DSHDesign", "DSHCore"]),

        // L1 插件网页单元
        .target(name: "DSHPluginUI", dependencies: ["DSHCore", "DSHDesign", "DSHConnectionDomain", dshKit]),

        // L1 文件单元
        .target(name: "DSHFilesDomain", dependencies: ["DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit]),
        .target(name: "DSHFilesUI", dependencies: ["DSHFilesDomain", "DSHDesign", "DSHCore"]),

        // 测试辅助：仅测试依赖
        .target(name: "DSHTestingSupport", dependencies: ["DSHCore", "DSHConnectionAPI", dshKit]),
    ]
)
