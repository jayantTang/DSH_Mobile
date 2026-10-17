// swift-tools-version: 6.0
import PackageDescription

// 端到端基准：真实中转 → 连接器 → DSHKit → 时间线/过程折叠。
// 不含 UI，因此不依赖仿真器；路径相对本包目录指向仓库里的两个本地包。
let package = Package(
    name: "history-live-bench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../../ios/DSHMobile/DSHKit"),
        .package(path: "../../../ios/DSHMobile/Modules"),
    ],
    targets: [
        .executableTarget(
            name: "history-live-bench",
            dependencies: [
                .product(name: "DSHKit", package: "DSHKit"),
                .product(name: "DSHChatDomain", package: "Modules"),
            ]
        ),
    ]
)
