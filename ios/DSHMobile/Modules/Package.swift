// swift-tools-version: 6.0
//
// DSHMobile 模块包（025 模块化重构；2026-10-21 层/单元目录重排）
//
// 目录即层，层内按单元内聚：
//
//   Foundation/            基础层（无依赖）
//   Design/                界面基础层（依赖 Foundation）
//   Contracts/             App 契约层（LinkService 等，依赖 DSHKit）
//   Core/                  服务层（HostEventHub / RouteIntent / ActivityModel）
//   Features/<Unit>/       功能单元层，单元内 Domain / UI / Tests 同居
//   Testing/               测试辅助（仅 test target 可依赖）
//
// L0 协议与数据在独立包 `../DSHKit`（DSHKit / RelayKit）。
// 依赖只允许向下；边界由 scripts/dev/check-module-boundaries.mjs 做路径级复核，
// 例外登记在 BOUNDARY-EXCEPTIONS.md。
//
// 每个 target 都用显式 `path:`：不再依赖默认 `Sources/`、`Tests/` 布局，
// 这样 `Features/Chat/Domain` 与 `Features/Sessions/Domain` 可以同名共存。

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
        // MARK: - 基础层

        // 零业务、零 UI
        .target(
            name: "DSHFoundation",
            path: "Foundation/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSHFoundationTests",
            dependencies: ["DSHFoundation"],
            path: "Foundation/Tests"
        ),

        // 横切设计系统：仅 SwiftUI
        .target(
            name: "DSHDesign",
            dependencies: ["DSHFoundation"],
            path: "Design/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSHDesignTests",
            dependencies: [
                "DSHDesign",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Design/Tests",
            // 快照由 SnapshotTesting 在运行期按 #filePath 读取，不需要作为 target 资源；
            // 不 exclude 会被 SwiftPM 当成未处理文件报警。
            exclude: ["__Snapshots__"]
        ),

        // MARK: - 契约层

        // 纯协议：连接服务接口
        .target(
            name: "DSHConnectionAPI",
            dependencies: [dshKit, relayKit],
            path: "Contracts/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - 服务层

        // 事件分发 / 传输编排 / 路由意图（禁 UI）
        .target(
            name: "DSHCore",
            dependencies: ["DSHConnectionAPI", "DSHFoundation", dshKit, relayKit],
            path: "Core/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSHCoreTests",
            dependencies: ["DSHCore", "DSHTestingSupport", dshKit],
            path: "Core/Tests"
        ),

        // MARK: - 功能单元层

        // 连接单元
        .target(
            name: "DSHConnectionDomain",
            dependencies: ["DSHConnectionAPI", "DSHFoundation", dshKit, relayKit],
            path: "Features/Connection/Domain",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSHConnectionDomainTests",
            dependencies: [
                "DSHConnectionDomain", "DSHConnectionAPI", "DSHTestingSupport", dshKit, relayKit,
            ],
            path: "Features/Connection/Tests/DomainTests"
        ),
        .target(
            name: "DSHConnectionUI",
            dependencies: ["DSHConnectionDomain", "DSHDesign", "DSHCore", "DSHFoundation", dshKit],
            path: "Features/Connection/UI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // 会话单元
        .target(
            name: "DSHSessionsDomain",
            dependencies: ["DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit],
            path: "Features/Sessions/Domain",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSHSessionsDomainTests",
            dependencies: ["DSHSessionsDomain", "DSHTestingSupport", dshKit, "DSHConnectionAPI", "DSHCore"],
            path: "Features/Sessions/Tests/DomainTests"
        ),
        .target(
            name: "DSHSessionsUI",
            dependencies: [
                "DSHSessionsDomain", "DSHDesign", "DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit,
            ],
            path: "Features/Sessions/UI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // 聊天单元：转写/流式/分页的领域层，与转写界面层
        .target(
            name: "DSHChatDomain",
            dependencies: ["DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit, relayKit],
            path: "Features/Chat/Domain",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 传输注入缝用例要 FakeLinkService + FakeCarrier（026 的 clientOverride），
        // 并直接点名 HostEventHub / ConnectionProfile。
        .testTarget(
            name: "DSHChatDomainTests",
            dependencies: [
                "DSHChatDomain", "DSHTestingSupport", "DSHCore", "DSHConnectionAPI", dshKit,
            ],
            path: "Features/Chat/Tests/DomainTests"
        ),
        .target(
            name: "DSHChatUI",
            dependencies: [
                "DSHChatDomain", "DSHDesign", "DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit,
            ],
            path: "Features/Chat/UI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // 设置单元
        .target(
            name: "DSHSettingsDomain",
            dependencies: ["DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit, relayKit],
            path: "Features/Settings/Domain",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSHSettingsDomainTests",
            dependencies: ["DSHSettingsDomain", "DSHTestingSupport", dshKit],
            path: "Features/Settings/Tests/DomainTests"
        ),
        .target(
            name: "DSHSettingsUI",
            dependencies: [
                "DSHSettingsDomain", "DSHDesign", "DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit, relayKit,
            ],
            path: "Features/Settings/UI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // 信箱单元
        .target(
            name: "DSHFeedbackDomain",
            dependencies: ["DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit, relayKit],
            path: "Features/Feedback/Domain",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSHFeedbackDomainTests",
            dependencies: ["DSHFeedbackDomain", "DSHTestingSupport", "DSHFoundation", dshKit, relayKit],
            path: "Features/Feedback/Tests/DomainTests"
        ),
        .target(
            name: "DSHFeedbackUI",
            dependencies: ["DSHFeedbackDomain", "DSHDesign", "DSHCore", relayKit],
            path: "Features/Feedback/UI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // 插件网页单元（暂无 Domain）
        .target(
            name: "DSHPluginUI",
            dependencies: ["DSHCore", "DSHDesign", "DSHConnectionAPI", "DSHFoundation", dshKit],
            path: "Features/Plugin/UI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // 文件单元
        .target(
            name: "DSHFilesDomain",
            dependencies: ["DSHCore", "DSHConnectionAPI", "DSHFoundation", dshKit, relayKit],
            path: "Features/Files/Domain",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSHFilesDomainTests",
            dependencies: ["DSHFilesDomain", "DSHTestingSupport", dshKit, "DSHConnectionAPI"],
            path: "Features/Files/Tests/DomainTests"
        ),
        .target(
            name: "DSHFilesUI",
            dependencies: ["DSHFilesDomain", "DSHDesign", "DSHCore", "DSHConnectionAPI", dshKit],
            path: "Features/Files/UI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - 测试辅助（仅 test target 依赖）

        .target(
            name: "DSHTestingSupport",
            dependencies: ["DSHCore", "DSHConnectionAPI", dshKit],
            path: "Testing/TestingSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    // 所有**生产 target** 已逐个显式打开 v6；测试 target 仍是 v5（手写夹具里
    // 大量非 Sendable 值，单独迁移）。包级默认保持 v5，新增 target 必须显式选模式。
    swiftLanguageModes: [.v5]
)
