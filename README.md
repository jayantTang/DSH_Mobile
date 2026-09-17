# DSH Mobile

[![CI](https://github.com/jayantTang/DSH_Mobile/actions/workflows/ci.yml/badge.svg)](https://github.com/jayanttang/DSH_Mobile/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**把电脑上的 [DSH](https://github.com/deepseek-ai/dsh)（DeepSeek Harness）装进手机。**

原生 iOS 客户端，手机与电脑连同一个 DSH host：看到同一批会话、同一条消息流，
电脑上跑着的任务锁屏再打开进度还在走，电脑上挂起的提问手机上直接答。
**手机在 4G/5G 上就能用——你的电脑不需要公网 IP，也不需要装 Tailscale。**

| 手机上读转写：工具调用、思考过程、最终答复 | 手机上管理连接：中转、已配对设备、权限 |
|---|---|
| ![会话转写](docs/artifacts/demo/02-transcript.jpg) | ![设置](docs/artifacts/demo/04-settings.jpg) |

> 左图出自一个**合成会话**：内容是真的 agent 输出，项目本身是编的。生成方式见
> [`docs/artifacts/demo/`](docs/artifacts/demo)——真实会话的截图不入库（带设备名与私有内容）。

```
┌──────────────┐        ┌────────────────────┐        ┌───────────────────┐
│  iPhone App  │  WSS   │  Relay（公网主机） │  WSS   │ 电脑侧连接器      │
│  SwiftUI     ├───────►│  仅鉴权 + 转发     │◄───────┤ (DSH 插件)        │
│  原生        │        │  不解析会话内容    │        │ 主动外连          │
└──────────────┘        └────────────────────┘        └─────────┬─────────┘
                                                                │ HTTP + WS
                                                       ┌────────▼────────┐
                                                       │ dsh web         │
                                                       │ 127.0.0.1:<port>│
                                                       └─────────────────┘
```

产品上**只提供「经公网中转」这一条连接方式**，不给用户选，理由见 [`docs/PAIRING.md`](docs/PAIRING.md)。

## 功能

- **会话**：按项目目录分组、归档与找回、按目录新建接续会话
- **对话**：流式输出、思考过程折叠、工具调用卡片、Markdown 与表格渲染、完成标记
- **问答**：host 端的提问卡片可直接在手机上作答，也支持自由输入
- **图片**：查看与点开放大；从相册或文件 App 发图进对话
- **文件**：分块上传任意文件到会话工作区；代码高亮、diff、HTML 报告预览
- **设备**：已配对设备列表与自助撤销；邀请码自助登记，别人也能连他们自己的电脑
- **通知**：任务跑完或需要确认时推送到手机（无声音频保活）
- **无线升级**：手机 Safari 打开发布页即可安装 / 覆盖升级，不需要数据线

## 组成

| 目录 | 内容 | 技术栈 |
|---|---|---|
| [`ios/DSHMobile/DSHKit`](ios/DSHMobile/DSHKit) | 协议核心：传输抽象、36 个 RPC、流式事件、时间线折叠 | Swift 6 Package，零 UI 依赖 |
| [`ios/DSHMobile`](ios/DSHMobile) | 原生 App | SwiftUI，iOS 17+ |
| [`plugins/mobile-link`](plugins/mobile-link) | 电脑侧连接器，随 `dsh web` 启动 | Node ESM（DSH 插件） |
| [`plugins/send-image`](plugins/send-image) | 让 agent 能把图片送进对话 | Node ESM（DSH 插件） |
| [`plugins/doubao-image`](plugins/doubao-image) | 用本机豆包 App 生成图片 | Node ESM（DSH 插件） |
| [`relay`](relay) | 公网中转：鉴权、路由、背压 | Python 3.12 + aiohttp + SQLite |
| [`docs`](docs) | 协议、架构与抓包样例 | — |

## 快速开始

**装完之后怎么用**——三步，先看这个：

```bash
# 1. 装连接器（npm 上的包，任何一台跑着 dsh 的电脑）
dsh plugin --profile web add dsh-plugin-mobile-link

# 2. 让这台电脑在中转上登记（邀请码由中转方给；自建中转的话跳过，见下）
dsh-mobile-link enroll --invite <邀请码> --relay wss://<中转地址>/dsh-link

# 3. 重启 DSH，然后在手机 App 里扫码配对（二维码在下面的「配对」一节）
dsh web
```

配对之后**不用再做任何事**：连接器随 `dsh web` 启动，手机断线会自动重连。
两端能力对照（手机能做什么、电脑上要开什么权限）见
[`docs/ONBOARDING.md`](docs/ONBOARDING.md)。

### 前置条件

| 用途 | 需要 |
|---|---|
| 电脑侧连接器 | Node.js 22+，以及一个可用的 `dsh web` |
| iOS App | 现成的安装包（TestFlight / OTA），或 macOS + Xcode 16（Swift 6）自己构建 |
| 中转 | **别人的中转 + 邀请码即可**；要自己开一台才需要 Python 3.12+ 与一台有公网 IP 的主机 |

### 1. 电脑侧连接器

```bash
dsh plugin --profile web add dsh-plugin-mobile-link   # npm
# 或者从 clone 出来的仓库装（注意开头的 ./）：
# dsh plugin --profile web add ./plugins/mobile-link
dsh web        # 连接器随 DSH 启动；插件改动需要重启 DSH 才生效
```

连接器不需要 `--trusted-host`：它始终以 `127.0.0.1:<port>` 访问 DSH，不改写 `Host`
（认证 Cookie 绑定 authority，本来也不能改），信任围栏看到的是回环地址。
详见 [`docs/notes/relay.md`](docs/notes/relay.md) §1。

### 2. 中转服务

中转是这个产品唯一的连接方式，所以跑起来之前你得有一个——**不一定是你自己的**：
拿别人的邀请码登记即可（连接器只指向那个中转，你不需要有一台机器）。

自己开一台的话：

```bash
cd relay
export DSH_RELAY_SITE=<你的站点>     # 仓库里只有占位符，站点地址属于部署方
sudo -E ./deploy/deploy.sh           # 幂等：建系统用户、装 systemd 单元、插入 Caddy 路由
python3 admin.py --db state.db account-create --name "Example"
python3 admin.py --db state.db invite-mint --note "给某人" --count 1   # 铸邀请码给对方
python3 admin.py --db state.db agent-register --account acc_x --name "MacBook Pro" \
    --write-config ~/.dsh/mobile-link/agent.json --relay wss://<你的站点>/dsh-link
```

> clone 下来直接构建的 App **默认连不上任何中转**——`relay.example.com` 是「未配置」的
> 哨兵，不是一个能连的地址（原因见下面的「配置：真值不入库」）。

`deploy.sh` 不新增 DNS 与证书：它把一段带标记的路由片段插进既有站点块，写入前先
`caddy validate`，失败即回滚；`--uninstall` 会按标记原样移除。细节见
[`relay/README.md`](relay/README.md)。

### 3. iOS App

**正常用法是装现成的包**（TestFlight，或发布页 OTA 安装），不是自己编译。自己构建只在
开发时用：

```bash
cd ios/DSHMobile
xcodebuild -scheme DSHMobile -destination 'platform=iOS Simulator,name=DSH-Test' build
```

### 4. 配对（手机 ↔ 这台电脑）

首次启动扫码或手输配对码，之后自动重连。二维码有两种拿法：

- 电脑上的 DSH 界面里打开「移动端连接」；
- 或者直接访问 `http://127.0.0.1:<dsh 端口>/mobile-link/qr`（要登录态；端口见
  `~/.dsh/desktop-shell/endpoint.json`）。

配对链接的形状：

```
dsh://pair?relay=https://relay.example.com/dsh-link&code=ABCD-1234
```

> `dsh://direct?host=…&port=…&token=…` 也能打开，但它是 **DEBUG-only 的测试通道**，
> 只给仿真器自动化用，不出现在任何用户界面里。

### 5. 确认它在工作

```bash
# 电脑侧：连接器状态（要带 DSH 的登录 cookie，浏览器里打开更省事）
curl -s "http://127.0.0.1:<dsh 端口>/mobile-link/status"
```

`state: "connected"` + `deviceCount ≥ 1` 就说明手机已经连上了。手机上打不开会话、
或者一直显示「电脑离线」时的排查顺序写在
[`docs/ONBOARDING.md`](docs/ONBOARDING.md)。

## 配置：真值不入库

仓库里出现的 `relay.example.com` 一律是**占位符**——中转地址属于部署方，不属于仓库。
真实地址只存在本机，且都被 gitignore：

| 位置 | 谁在用 | 怎么给真值 |
|---|---|---|
| `.env.local` | 发布脚本、`scripts/dev/dsh-probe.mjs` | `cp .env.example .env.local`，填 `DSH_SITE` / `DSH_RELAY_URL` / `DSH_OTA_HOST` |
| `~/.dsh/mobile-link/agent.json` | 连接器的中转地址与身份（登记后写在这里） | 跑一次 `dsh-mobile-link enroll --invite <码> --relay <地址>`；要临时覆盖再设 `DSH_RELAY_URL`（必须进 DSH 进程的环境，DSH 自己不读 `.env.local`） |
| `ios/DSHMobile/Config.local.xcconfig` | App 内预填的中转地址与更新源（构建时注入 Info.plist） | `cp ios/DSHMobile/Config.xcconfig ios/DSHMobile/Config.local.xcconfig`，填 `DSH_RELAY_URL` / `DSH_UPDATE_FEED` |
| 服务器环境变量 | `relay/deploy/deploy.sh` 决定插进哪个 Caddy 站点块 | 在服务器上 `export DSH_RELAY_SITE=<你的站点>` |

占位符 `relay.example.com` 是「没配置」的哨兵，不是一个可以连的地址：配置里的占位符
不会盖掉 `agent.json` 里已登记的真实地址。

因此 clone 下来直接构建的 App **默认连不上任何中转**，这是有意为之。Xcode 工程用
`#include?` 可选包含本机那份 xcconfig，文件不存在时自动跳过，不会构建失败；读取处见
[`Support/AppConfig.swift`](ios/DSHMobile/DSHMobile/Support/AppConfig.swift)。

发布 OTA 还需要一个 Apple 开发者团队 ID（同样属于人、不属于仓库）：写在
`ios/DSHMobile/Signing.local.plist`（`{ teamID = XXXXXXXXXX; }`）或用 `DSH_TEAM_ID` 传入。

## 测试

```bash
cd ios/DSHMobile/DSHKit && swift test         # 协议层：58 项（1 skip）
cd plugins/mobile-link && npm test            # 连接器：104 项
cd relay && .venv/bin/python -m pytest -q     # 中转：107 项（1 skip）
```

三个插件包都零依赖，`npm test` 直接可跑；中转那份要先装依赖：

```bash
cd relay && python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
```

协议层的集成测试在本机没有运行 DSH 时会自动跳过，且只使用只读端点。

上面这几套测试由 GitHub Actions 在**干净仓库**上各跑一遍（relay 那份依赖里补上了
`pytest-aiohttp`——它此前只装在作者本机的 venv 里），外加一个「不带任何本机配置」的
App Release 构建，也就是别人 clone 下来的样子：见
[`.github/workflows/ci.yml`](.github/workflows/ci.yml)。需要仿真器、真实中转、开发者
团队 ID 或手机在环的验证**不在 CI 里**（只能在真机上按规范做）——CI 绿不等于可以发布。

界面测试是一套独立的测试台，入口在 [`test/`](test)：

```bash
./test/run.sh prepare
./test/run.sh run test/cases/fixed/01-全部独立页面逐屏核对.md
./test/run.sh report --verdict 通过 --note "一句话结论"
```

判定口径见 [`test/RULES.md`](test/RULES.md)，报告格式见
[`test/REPORT-CONTRACT.md`](test/REPORT-CONTRACT.md)（`report` 会按它 lint）。

## 协议核心

DSH 的客户端协议是 schema 驱动的 RPC 加一条多路复用 WebSocket，DSHKit 完整实现了它：

- **认证**：手机用配对码向中转换 `deviceToken`，中转按 `agentId` 转发帧；连接器再以
  `127.0.0.1:<port>` 访问 DSH，host 侧的 authority 与信任围栏不受影响
- **一元 RPC**：`POST /api/<method>`，body 形如
  `{"type":"client-request","rpcId":…,"method":…,"payload":{"args":{…}}}`；
  `args` 是命名字段对象，由 host 侧 descriptor 严格校验
- **流式**：WebSocket `/api/remote.mux`，用
  `{"type":"open","streamId":…,"endpoint":…,"payload":{"args":…}}` 打开逻辑流；
  **必须用文本帧**，二进制帧会被 host 以 `1003` 关闭
- **宿主事件**：`$events` 推送 `emit` 与 `waterfall`；waterfall 会阻塞 host，
  必须经 `$events/result` 应答，多客户端时首答生效

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/DSH-PROTOCOL.md`](docs/DSH-PROTOCOL.md) | DSH 原生协议参考（权威、实现导向） |
| [`docs/RELAY-PROTOCOL.md`](docs/RELAY-PROTOCOL.md) | DLP v1 中转协议规范 |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 架构与关键决策 |
| [`docs/PAIRING.md`](docs/PAIRING.md) | 连接方式与配对设计 |
| [`docs/ONBOARDING.md`](docs/ONBOARDING.md) | 装完之后怎么用：五步跑通、能力对照、连不上怎么查 |
| [`docs/IMAGES.md`](docs/IMAGES.md) | 图片能力的设计约束与实现 |
| [`docs/VERSIONING.md`](docs/VERSIONING.md) | 三处部署的版本与发布策略 |
| [`docs/dsh-rpc-catalog.json`](docs/dsh-rpc-catalog.json) | 机器可读的 RPC 目录 |
| [`docs/notes/relay.md`](docs/notes/relay.md) | 实现与规范的偏差记录（中转侧） |
| [`docs/notes/connector.md`](docs/notes/connector.md) | 规范未覆盖处的连接器选择 |
| [`docs/artifacts/samples/`](docs/artifacts/samples) | 从真实 DSH 抓取的响应样例（已脱敏） |
| [`docs/artifacts/demo/`](docs/artifacts/demo) | README 配图：合成会话与截图口径 |

## 已知限制

- 文件发送只在经中转时可用；直连测试通道会返回 404
- 后台通知靠无声音频保活，只在「有会话在跑或有待回答的提问」时生效
- 手机处于后台时，电脑端**新开始**的会话叫不醒 App——那需要 APNs，尚未实现
- OTA 安装依赖描述文件有效期，到期前需重新构建续期；长期分发应改用 TestFlight

## 许可

MIT，见 [`LICENSE`](LICENSE)。
