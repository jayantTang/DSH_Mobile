# 可独立进入的页面

写用例时的目标表。`根标识` 是进入该页后**必须出现**的元素，用于判断页面是否真的到了；
`启动参数` 是 App 里 DEBUG-only 的自动化钩子（`RootView.swift`），用来省掉点按。

| 页面 | 根标识 | 启动参数 | 说明 |
|---|---|---|---|
| 连接页（未连接） | — （用 `text:连接你电脑上的 DSH` 判断） | 不带 `-DSHConnectURL` | 首次启动或连接失败时的落地页 |
| 会话列表 | `session.list` | `-DSHConnectURL <url>` | 工具栏含「连接管理」「设置」「新建会话」三个入口；列表底部是**两个互不相干**的折叠区：`session.ungrouped`（未分组，来自工作区之外）与 `session.archived`（已归档，被归档收走的） |
| 会话转写 | `chat.transcript` | `-DSHConnectURL <url> -DSHOpenSession <id>` | 需要真实会话 id，`test/tools/host.mjs` 可挑一个 |
| 工作区文件 | `files.root` | `-DSHConnectURL <url> -DSHOpenScreen files` | 取会话列表里第一个会话的工作区 |
| 设置 | `settings.root` | `-DSHConnectURL <url> -DSHOpenScreen settings` | 弹层 |
| 连接管理 | `connection.scan` | `-DSHConnectURL <url> -DSHOpenScreen connections` | 弹层，含扫码入口 |

`-DSHOpenScreen` 支持的值由 `RootView.swift` 的 `automationScreen()` 决定，
新增页面时同时改这里和 `test/cases/fixed/01-全部独立页面逐屏核对.md`。

## 诊断屏

| 页面 | 根标识 | 启动参数 | 说明 |
|---|---|---|---|
| 设备诊断 | `text:system font` | `-DSHOpenScreen diagnostics` | 列出设备字体族，并回答系统字体能否画某个汉字。排查渲染类问题用。 |
