// swift-tools-version: 6.0
import PackageDescription

// 历史页解码基准（离线，只读）。
//
// 为什么单独一个包：它是开发期量尺，不是产品代码；放进 DSHKit 会多一个测试目标、
// 跟着 iOS 构建走，而这里只需要 macOS 上能以 release 跑出稳定数字。
// 依赖方向只有一条：这个工具 → DSHKit（不反向）。
let package = Package(
    name: "history-page-bench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../../ios/DSHMobile/DSHKit"),
    ],
    targets: [
        .executableTarget(
            name: "history-page-bench",
            dependencies: [.product(name: "DSHKit", package: "DSHKit")],
            path: "Sources/history-page-bench"
        ),
    ]
)
