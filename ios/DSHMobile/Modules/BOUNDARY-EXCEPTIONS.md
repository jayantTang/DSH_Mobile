# 边界例外登记（契约 C5）

暂无法满足模块边界契约的引用，逐条登记在此。规则：**例外只减不增**——
`npm run check:module-boundaries` 会拦截例外数上升；每条必须给出收敛方向与期限。

| 位置 | 违反条款 | 原因 | 收敛方向与期限 |
|---|---|---|---|
| Modules/Sources/DSHConnectionDomain/ConnectionStore.swift（UIDevice.current.name，#if canImport(UIKit)） | C2 禁 UI | 拿设备名做配对显示，iOS 平台 API；已用条件编译限制到 iOS，macOS 构建不引入 | 收敛：抽一个 DeviceInfo 端口到 DSHFoundation，由 App 注入；本轮不做（025 阶段3后续） |
| Modules/Sources/DSHFoundation/DeviceInfo.swift（UIDevice，#if canImport(UIKit)） | C2 禁 UI | 设备/系统信息是 iOS 平台 API；026 把三处分散的 UIDevice 收敛成这一个文件（正是前两条例外的收敛方向） | 收敛完成：这是目的地方案，不再迁移 |
