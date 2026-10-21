# Modules 分层与依赖矩阵

> 目录即层：`Modules/` 顶层各目录就是层，`Features/<Unit>` 内是单元。
> 判定口径在 `scripts/dev/check-module-boundaries.mjs`（C1/C2/C6/C7/C8/C9）；
> 本文是人读版，改矩阵时两边一起改。

## 层

| 层 | 目录 | target | 允许依赖 |
|---|---|---|---|
| 基础 | `Foundation/` | `DSHFoundation` | 无 |
| 界面基础 | `Design/` | `DSHDesign` | `DSHFoundation` |
| 契约 | `Contracts/` | `DSHConnectionAPI` | `DSHKit` |
| 服务 | `Core/` | `DSHCore` | `Contracts`、`Foundation`、`DSHKit`、`RelayKit` |
| 功能单元 | `Features/<Unit>/Domain` | `DSH<Unit>Domain` | `Core`、`Contracts`、`Foundation`、`DSHKit`、`RelayKit` |
| 功能单元 | `Features/<Unit>/UI` | `DSH<Unit>UI` | 本单元 Domain、`Contracts`、`Design`、`Core`、`Foundation`、`DSHKit`、`RelayKit` |
| 测试辅助 | `Testing/` | `DSHTestingSupport` | `Core`、`Contracts`、`Foundation`、`DSHKit`、`RelayKit`；只允许 test target 依赖 |

`Features/Plugin` 目前只有 UI，没有 Domain。

## 约束

1. 依赖只向下；`*Domain` 不得依赖 `*UI`，单元之间不得互相依赖。
2. UI 只允许依赖**本单元** Domain；连接状态经 `Contracts` 的 `ConnectionEnv`
   （`DSHConnectionAPI`），不再依赖 `Features/Connection/Domain`。ConnectionUI 走
   “同单元 UI → Domain”的结构性配对边，不属于跨单元依赖。
3. `*Domain` 不得直接引用实现层类型：`SessionPipeline`、`MessagePipeline`、
   `MessageStore`、`DSHClient`、`LinkCarrier`（Connection 适配器除外）。数据能力走
   `MessageLayer` / `SessionHandle`；连接能力走 `LinkService`。
4. 每个 target 必须显式 `path:`；`Modules/` 下每个 `.swift` 必须落在某个 target 路径内。
5. 所有生产 target 必须显式 `swiftSettings: [.swiftLanguageMode(.v6)]`。包级默认是
   v5；测试 target 暂留 v5（手写夹具里大量非 Sendable 值）。
6. 测试辅助只给 test target 用；产品 target 依赖 `DSHTestingSupport` 会被 C1 拒绝。

## 检查

```bash
npm run check:module-boundaries
npm run check:public-api
```

`check:public-api` 优先用 SwiftPM symbol graph 统计 DSHKit **真实可 import**
的导出符号（预算 2,200）；本机没有 Swift 工具链时退回 public 关键字粗筛
（1,665 声明 / 283 类型）。

**公开面规则**：新增公开 API 必须同时迁出等价旧 API；预算不因单次需求直接调高。
当前余量只有 19 个 symbol，任何新增公开模型/协议都要先说明“删了什么”。

例外登记在 `BOUNDARY-EXCEPTIONS.md`，只减不增。
