# DSH Mobile

**中文** · [English](README.en.md)

[![DSH plugin](https://img.shields.io/badge/DSH-plugin-4D6BFE)](https://github.com/deepseek-ai/deepseek-harness)
[![listed in awesome-deepseek-harness](https://img.shields.io/badge/listed%20in-awesome--deepseek--harness-4D6BFE?logo=awesomelists&logoColor=white)](https://github.com/Dominic789654/awesome-deepseek-harness)
[![Awesome](https://awesome.re/badge.svg)](https://github.com/Dominic789654/awesome-deepseek-harness)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white)](docs/VERSIONING.md)
[![TestFlight](https://img.shields.io/badge/TestFlight-join-0D96F6?logo=apple&logoColor=white)](https://testflight.apple.com/join/tHKQsbCk)
[![connector on npm](https://img.shields.io/npm/v/dsh-plugin-mobile-link?label=connector)](https://www.npmjs.com/package/dsh-plugin-mobile-link)
[![CI](https://github.com/jayantTang/DSH_Mobile/actions/workflows/ci.yml/badge.svg)](https://github.com/jayantTang/DSH_Mobile/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

把电脑上的 [DSH](https://github.com/deepseek-ai/deepseek-harness) 会话接到 iPhone 与 iPad：原生 iOS
客户端、电脑侧连接器、可自建的公网中转。手机经中转连接电脑上的 DSH host，会话与消息流与电脑端
一致；任务在电脑锁屏后继续运行，挂起的提问可在手机上作答。电脑无需公网 IP，也无需 VPN。

![DSH Mobile 演示：电脑端登记、手机扫码配对，查看会话、远程文件、git 改动与提交历史](docs/artifacts/demo/dsh-mobile-demo.gif)

## 状态与兼容性

| 组件 | 分发方式 |
|---|---|
| iOS App | TestFlight（[加入](https://testflight.apple.com/join/tHKQsbCk)），构建 90 天过期 |
| 连接器 `dsh-plugin-mobile-link` | npm |
| 中转（DLP v1） | `relay-go/`（Go），自行部署 |

连接器与 iOS App 请保持最新版本：两者按同一份协议演进，跨版本的兼容窗口有限。
版本组合与兼容性约束见 [`docs/VERSIONING.md`](docs/VERSIONING.md)。

## 前提

- 电脑已安装并可运行 DSH（`dsh web`）；连接器需要 Node.js ≥ 22。
- 自建中转需一台有公网 IP 的主机（macOS 或 Linux）与 Caddy。
- 从源码构建 App 需 macOS + Xcode 16 以上；日常使用不需要。

## 快速开始

### A. 使用公共中转

1. 安装 App：加入 [TestFlight 公开测试](https://testflight.apple.com/join/tHKQsbCk)（需先安装 TestFlight）。
2. 安装连接器，装进实际在用的宿主档案（装错不会报错，但连接器不会被加载）：
   - 命令行 web 版：`dsh plugin --profile web add dsh-plugin-mobile-link`
   - 官方桌面版：用应用内插件页，或应用自带的 `dsh` 命令装进 `desktop` 档案（普通 npm 版 `dsh`
     会拒绝该档案）。两种宿主的识别判据见 [`docs/ONBOARDING.md`](docs/ONBOARDING.md)。
3. 登记：DSH 左下角「移动端连接」→ 确认中转地址 →「登记」。开放登记，无需邀请码，按来源限流；
   无头环境用 `dsh-mobile-link enroll --relay wss://<中转地址>/dsh-link`。
4. 生效：安装插件与面板登记均无需重启；仅命令行登记且宿主正在运行时需重启一次。
5. 配对：App「扫码配对」扫描面板中的二维码与配对码；配对码点「重新生成」才会更换。

顶部显示「已连接」即为成功；完整步骤与故障排查见 [`docs/ONBOARDING.md`](docs/ONBOARDING.md)。

### B. 自建中转

自建使用仓库内 Go 实现（`relay-go/`）。构建与安装见
[`relay-go/deploy/README.md`](relay-go/deploy/README.md) §2–§4；Caddy 路由用
[`Caddyfile.snippet`](relay-go/deploy/Caddyfile.snippet) 配合
[`caddy_splice.py`](relay-go/deploy/caddy_splice.py) 插入站点块。

```bash
sudo systemctl enable --now dsh-relay-go
```

实时负载与每设备用量：`curl -s http://127.0.0.1:8787/stats`（仅监听回环）。限额与运维细节见
[`relay-go/README.md`](relay-go/README.md) 与 [`relay-go/deploy/README.md`](relay-go/deploy/README.md)。

## 组件与数据流

```
┌──────────────┐   WSS    ┌────────────────────┐   WSS    ┌───────────────────┐
│  iOS App     ├─────────►│  Relay（公网主机）  │◄─────────┤ 电脑侧连接器       │
│  SwiftUI     │          │  鉴权 + 转发        │          │ (DSH 插件)        │
└──────────────┘          └────────────────────┘          └─────────┬─────────┘
                                                                     │ HTTP + WS
                                                           ┌─────────▼─────────┐
                                                           │ dsh web           │
                                                           │ 127.0.0.1:<port>  │
                                                           └───────────────────┘
```

| 组件 | 位置 | 职责 |
|---|---|---|
| iOS App | 手机 | 会话列表、转写、图片与文件、配对与设备管理 |
| 连接器 | 电脑（DSH 插件） | 以 `127.0.0.1` 访问本机 DSH，转成中转帧 |
| 中转 | 公网主机 | 鉴权与按 `agentId` 转发；**不解析会话内容** |
| DSH host | 电脑 | 会话、agent 与工具的真实执行方 |

产品上只提供经中转这一条连接方式；`dsh://direct` 是 DEBUG-only 的测试通道。选型与边界见
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 与 [`docs/PAIRING.md`](docs/PAIRING.md)。

## 配置

仓库中的 `relay.example.com` 一律为占位符：中转地址由部署方决定，不属于仓库。真值只存在于本机并被
gitignore：

| 位置 | 用途 | 提供方式 |
|---|---|---|
| `.env.local` | 发布脚本、开发探针 | `cp .env.example .env.local`，按模板填站点与中转地址 |
| `~/.dsh/mobile-link/agent.json` | 连接器的中转地址与身份 | 面板「登记」，或 `dsh-mobile-link enroll --relay <地址>` |
| `ios/DSHMobile/Config.local.xcconfig` | App 内预填的中转地址与更新源 | 从 `Config.xcconfig` 复制后填写 |

直接 clone 构建的 App 不含中转地址，属有意设计。

## 开发

```bash
cd ios/DSHMobile/DSHKit && swift test        # 协议层
cd plugins/mobile-link  && npm test          # 连接器
cd relay-go && make test                     # 中转（Go，生产实现）
cd mail && ../.venv/bin/python -m pytest -q   # 信件服务
npm run check:secrets                        # 本机真值没有进跟踪文件
npm run check:docs                           # 文档规范（结构、口吻、链接）

cd ios/DSHMobile && xcodebuild -scheme DSHMobile \
  -destination 'platform=iOS Simulator,name=DSH-Test' build
```

上述单测与一次不带本机配置的 Release 构建由 GitHub Actions 执行。需要仿真器、真实中转或开发者团队
ID 的验证不在 CI 内；CI 通过不等于可以发布。

界面测试为独立测试台：`./test/run.sh prepare` → `run <用例>` → `report --verdict …`；口径见
[`test/RULES.md`](test/RULES.md)，模板见 [`test/examples/`](test/examples)。

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/ONBOARDING.md`](docs/ONBOARDING.md) | 两种部署路径的选择、操作步骤、故障排查 |
| [`docs/GLOSSARY.md`](docs/GLOSSARY.md) | 术语表（DSH、host、连接器、中转、DLP 等） |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 架构与关键决策 |
| [`docs/DSH-PROTOCOL.md`](docs/DSH-PROTOCOL.md) | DSH 原生协议参考（权威、面向实现） |
| [`docs/RELAY-PROTOCOL.md`](docs/RELAY-PROTOCOL.md) | DLP v1 中转协议规范 |
| [`docs/CONNECTOR-NOTES.md`](docs/CONNECTOR-NOTES.md) / [`docs/RELAY-NOTES.md`](docs/RELAY-NOTES.md) | 实现与规范的偏差记录 |
| [`docs/PAIRING.md`](docs/PAIRING.md) | 连接方式与配对设计 |
| [`docs/IMAGES.md`](docs/IMAGES.md) | 图片能力的设计约束与实现 |
| [`docs/VERSIONING.md`](docs/VERSIONING.md) | 三处部署的版本与发布策略 |
| [`docs/PRIVACY.md`](docs/PRIVACY.md) | 隐私说明：App 不收集数据，中转只做转发 |
| [`docs/dsh-rpc-catalog.json`](docs/dsh-rpc-catalog.json) | 某次快照：机器可读的 RPC 目录（不是持续校验的契约） |
| [`docs/artifacts/samples/`](docs/artifacts/samples) | 从真实 DSH 抓取的响应样例（已脱敏） |

开发约定见 [`CONTRIBUTING.md`](CONTRIBUTING.md)，安全问题见 [`SECURITY.md`](SECURITY.md)，版本变化见
[`CHANGELOG.md`](CHANGELOG.md)。

## 已知限制

- **后台通知**：App 退到后台后，任务完成与待答提问仍推送至手机；无任务、无提问时不推送。
- **不覆盖**：电脑端新开始的会话无法唤起 App（需 APNs，尚未实现）；长时间未答的提问可能丢失。
- 文件发送仅在经中转时可用。

## 许可

MIT，见 [`LICENSE`](LICENSE)。
