# 架构与不变量

本文件写系统结构与修改原则；用户行为见 `handbook/requirements/`。

## 部件

| 部件 | 路径 | 形态 |
|---|---|---|
| 协议核心 | `ios/DSHMobile/DSHKit` | 独立 Swift Package，零 UI 依赖，可在 macOS 上运行单测 |
| iOS App | `ios/DSHMobile/DSHMobile` | SwiftUI，iOS 17+ |
| 电脑侧连接器 | `plugins/mobile-link` | DSH 插件（Node ESM），随 `dsh web` 启动 |
| 图片插件 | `plugins/send-image`、`plugins/doubao-image` | DSH 插件 |
| 公网中转 | `relay-go/` | Go 单二进制 + SQLite，systemd 沙箱 + Caddy 路由片段（`relay-go/deploy/`） |
| 仿真器测试台 | `test/` | Node 驱动 XCUITest，带报告契约与 lint |

链路：`iPhone App → WSS → relay → WSS → 连接器 → 127.0.0.1:<port> → dsh web`。

## 插件双宿主

插件必须同时支持官方桌面版与 web 两个宿主（owner 2026-10-07 要求）。两个宿主各有独立档案（`~/.dsh/profiles/desktop` 与 `profiles/web`），同一插件改动必须在两边都能用；只在一边注册的依赖或配置块会导致另一边失效。已实测两次：只在 web 档案注册的模型提供方（`company-gateway`）切到官方桌面版后报 `no adapter registered for provider`，手机发消息立即失败；只在 web 档案挂载的 browse 目录后端未同步到桌面版，「新建会话」的目录浏览功能整体失效（根因见 `handbook/history/验收/004-桌面宿主对等.md`）。

对等检查：`npm run check:parity`（即 `node scripts/dev/profile-parity.mjs`）比较插件、bundle 与 `cordis.patch.yml` 的配置块 id 与规范化内容；只装单宿主或某档案被应用重置都会报错。只查看差异用 `--report`，单宿主机器加 `--allow-missing`。

补齐差异：`npm run parity:apply`（预演）→ `npm run parity:apply -- --write`（先备份，幂等；内容不同的块需显式加 `--overwrite`）→ `npm run restart`。两个档案位于 `~/.dsh` 下、不在仓库中，agent 沙箱通常无法写入，因此补齐操作交给该命令，不要手工编辑 YAML。

安装路径同样对等：`scripts/install/install-plugin.sh` 默认把插件装入 `web` 与 `desktop` 两个档案（存在哪个就装哪个），`install-all.sh` 的收尾校验会检查两个档案。修改插件后需在两个宿主各运行一次，再按发布节奏发布。

## 修改原则

修复问题不得打补丁（owner 2026-10-18 要求，适用于 iOS、连接器、中转与脚本）。

- 方案先回答「这个状态或职责归谁」，再讨论改哪一行。仅通过增加判断、开关、特例或缓存绕过症状的，不算方案。
- 一个事实只能有一个所有者。同一状态不得在视图、模型、管道各存一份；出现两份时先合并，再修改。
- 不得用「再来一次 / 多等一会 / 多试几遍」掩盖竞态或未知终态。成功、失败、超时、取消四种结局都必须落到可见状态；未知即错误态，并提供可重试入口。
- 不得为减少改动而复制第二条通路（第二份缓存、第二个开关、第二套解析）。新增通路必须替换旧通路，并在同一次改动中删除旧通路。
- 改动须附同层单元测试（纯函数或状态机），并在改动记录中写明：根因、职责归属、迁移与回滚路径、被删除的旧行为。
- 自检标准是「半年后是否仍成立」：需要注释提醒、依赖记忆，或必须与旧代码并存才能成立的修法，视为不合格。
