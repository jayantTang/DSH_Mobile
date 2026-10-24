# 装完之后怎么用

**中文** · [English](ONBOARDING.en.md)

> 面向：使用者 · 状态：stable · 最近核对：2026-09-20

一页讲完「两条路怎么选」和「对不上怎么查」。第一次用的人看这个，回答 issue 的人也从这里引用。

---

## 两条路，先选一条

| | **A · 用现成中转**（推荐） | **B · 自己开中转** |
|---|---|---|
| 适合谁 | 只想赶紧用起来 | 想要完全自主、不依赖别人的机器 |
| 前提 | 一个邀请码（一次性，绑一台电脑；在 [issue #1](https://github.com/jayantTang/DSH_Mobile/issues/1) 领） | 一台有公网 IP 的主机（能装 Caddy） |
| 耗时 | 约 5 分钟 | 约 20 分钟 |
| 你要做什么 | 装连接器 → 填邀请码 → 扫码 | 部署中转 → 铸码 → 同上 |

**两条路在第 4 步之后完全一样**：手机扫码配对、之后自动重连。

---

## 你要先有三个东西

| 东西 | 从哪来 | 没有会怎样 |
|---|---|---|
| 跑着 DSH 的电脑 | `npx @deepseek-ai/dsh web` | 手机连上了也没会话可看 |
| 电脑上的连接器 | 按宿主安装（见「安装：官方桌面版」/「安装：命令行 web 版」） | 手机扫不出配对码，或连上就断 |
| 手机上的 App | TestFlight 公开链接：<https://testflight.apple.com/join/tHKQsbCk>（先装 TestFlight） | — |

中转不是第四个东西：A 用别人的，B 自己开。区别只是「谁是那台公网机器」。

---

## 如何识别你的宿主

连接器装在**运行 DSH 的那个进程**里，所以先认清楚自己用的是哪一种：

| 你的情况 | 宿主 | 走哪一节 |
|---|---|---|
| 双击图标打开的桌面应用（DeepSeek Harness） | **官方桌面版** | 见下方「安装：官方桌面版」 |
| 在终端敲 `dsh web`（或 `npx @deepseek-ai/dsh web`） | **命令行 web 版** | 见下方「安装：命令行 web 版」 |
| 以前用过一个叫 `DSH.app` 的窗口外壳（本项目旧版本提供的） | **已不再支持** | 见下方「从自研外壳迁移」 |

一句话判据：**双击图标 = 官方桌面版；敲命令 = 命令行 web 版。** 两种宿主各自有独立的插件档案，
装插件要装进你实际在用的那一个；装错了不会报错，只是连接器不会被加载（表现是手机一直连不上）。

## 安装：官方桌面版

用应用内的**插件页**安装（推荐）。若用命令行，必须用**应用自带的那条 `dsh`**
（普通 npm 安装的 `dsh` 会拒绝这个档案，这是官方设计）：

```bash
"/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh" \
  plugin --profile desktop add dsh-plugin-mobile-link
```

（应用装在别处就换掉前半段路径；这条命令就是应用自带的那个 `dsh`。）

两个前置条件（不满足会失败）：

1. 应用**先启动过一次**，让它初始化自己的档案；
2. 装插件前**完全退出应用**（否则档案被占用，命令会被挡住）。

装完重新打开应用即可，然后按「排查：连不上时看这里」确认：状态里 `host` 应为 `desktop`。
**另一条安装命令（`--profile web`）在这台电脑上不适用**：那条是给命令行 web 版用的。

## 安装：命令行 web 版

```bash
dsh plugin --profile web add dsh-plugin-mobile-link
```

装完**重启** `dsh web`。**另一条安装命令（`--profile desktop`）在这台电脑上不适用**：
那个档案归官方桌面版所有，普通 `dsh` 拒绝管理它。

## 从自研外壳迁移

我们自己的 `DSH.app`（自研 macOS 外壳）**自本版起不再支持，并且已经从仓库与本机移除**。
从它迁移不需要任何额外操作：

- 换用官方桌面版：装连接器的方式见「安装：官方桌面版」；
- 或换用命令行 web 版：见「安装：命令行 web 版」。

**没有数据要迁移**：会话、凭据、工作区都在同一份 `~/.dsh` 下，换宿主不会丢。连接器也不再
依赖外壳写下任何交接文件——它现在直接在宿主进程里获知本机地址，重启宿主后自动重新获知。

## 装在哪里：档案与插件入口

| 宿主 | 档案 | 装插件的入口 |
|---|---|---|
| 官方桌面版 | `desktop`（应用独占，npm 版 `dsh` 拒绝管理） | 应用内插件页，或应用自带的 `dsh` 命令 |
| 命令行 web 版 | `web` | `dsh plugin --profile web add dsh-plugin-mobile-link` |

判断"装没装对"最直接的方法：看状态里的 `host` 字段（见下方「排查：连不上时看这里」）。
`host` 是 `desktop` 还是 `web`，取决于**当前正在运行的**宿主，而不是你曾经装过哪里。

## 手工指定本机地址

通常不需要。若连接器拿不到宿主提供的地址（例如在宿主进程之外单独跑它），可以显式给一个：

```bash
dsh-mobile-link --dsh-url "http://127.0.0.1:<端口>/?token=<令牌>"
```

注意：带令牌的地址**只在宿主本次运行期间有效**，宿主重启后必须换新的。它的来源：

- 命令行 web 版：`dsh web` 启动时打印的那一行；
- 官方桌面版：没有用户可见的打印，看状态里的 `dsh.endpoint`。

## 排查：连不上时看这里

先看状态里这几个字段，它们直接说明问题在哪。**状态怎么打开**（需要 DSH 的登录态，
所以用本机浏览器，别用手机）：

- 命令行 web 版：`dsh web` 启动时打印的那一行里有端口，形如
  `dsh web: http://127.0.0.1:<端口>/?token=…`；浏览器打开
  `http://127.0.0.1:<端口>/mobile-link/status`。
- 官方桌面版：直接看应用界面里的「移动端连接」。

状态里的 `dsh` 这一块就是下面这几个字段：

| 字段 | 含义 | 下一步 |
|---|---|---|
| `host` | 当前宿主形态 | `unknown` = 认不出宿主，按上面「如何识别你的宿主」对一遍 |
| `dsh.authenticated` | 是否已与本机 DSH 握手成功 | `false` 时看下面的 `dsh.errorKind` |
| `dsh.errorKind` | 失败分类 | `host-service` = 插件多半没装进正在运行的宿主；`config` / `DSH_WEB_URL` = 手工给的地址过期；`unreachable` = 宿主没在跑 |

`host` 是 `desktop` / `web` / `unknown`；`dsh.errorKind` 为 `null` 表示本机侧正常，
问题在别处（中转或手机侧）。

本机这一侧正常、手机仍连不上或时断时续时，**不要靠猜**：一条命令取一个诊断包，
它把手机、中转、连接器三侧的记录对齐到同一个时钟，能直接看出停在哪一跳。
采集与判读见 `docs/DIAGNOSTICS.md`（`npm run diag:collect`）。

---

## A · 用现成中转（5 分钟）

### 第 1 步：手机装 App

Safari（不要用微信内置浏览器）打开邀请页 → **接受邀请** → 若没装 TestFlight 会先跳去 App Store
装它 → 回到 TestFlight 点 **安装**。

> TestFlight 构建 **90 天后过期**，到期那天 App 会提示并打不开，需要装新构建（仓库 issue 里会说）。

### 第 2 步：电脑装连接器

按你的宿主选一条（认不清就先看「如何识别你的宿主」）：

- **官方桌面版**：见「安装：官方桌面版」
- **命令行 web 版**：

```bash
dsh plugin --profile web add dsh-plugin-mobile-link
```

### 第 3 步：用邀请码把这台电脑登记到中转

邀请码与中转地址一起给你，形如：

```bash
dsh-mobile-link enroll --invite ABCD-EFGH-JKLM-NPQR --relay wss://<中转地址>/dsh-link
```

成功后身份写在 `~/.dsh/mobile-link/agent.json`，**这台电脑以后不用再登记**。
（也可以用环境变量代替参数：`DSH_MOBILE_LINK_INVITE=<码> dsh web`，适合写进服务配置。）

### 第 4 步：让连接器用上刚登记的身份

**装插件本身不需要重启**：命令行 web 宿主会自己把新装的插件挂上（实测：装完不重启，连接器当场出现在
宿主里，宿主进程都没换）。桌面版由应用自己管插件，按应用内的提示做。

需要「重新加载一次」的是**登记**：连接器在没身份的时候会放弃那一轮运行，所以第 3 步登记完之后要让它
重新读一次身份。两条路：

```bash
# 路一：重启宿主（最省事，也是默认说法）
ps -eo pid,lstart,command | grep 'bin/dsh web' | grep -v grep   # 看现在的进程
# 退出 DSH 后重新启动
dsh web
```

```bash
# 路二：启动时就把邀请码给它——登记与连接在同一次启动里完成，不用重启
DSH_MOBILE_LINK_INVITE=<邀请码> dsh web
```

（路二就是第 3 步里的环境变量写法；中转地址也可以用 `DSH_RELAY_URL` 一起给。）

### 第 5 步：扫码配对

电脑上打开二维码：点 DSH 界面**左下角的「移动端连接」**（侧栏底部，带一个连接状态点）。
小窗里有连接状态、二维码、配对码文本与有效期；电脑端与手机端都不需要知道中转地址——
二维码里已经带着它。

手机 App → **扫码配对** → 扫它。相机不可用时，连接页底部有一行「扫不了码？手动输入配对码」，
点开可以手输小窗里那串配对码。

屏幕上那张码永远是可以扫的：它被兑换掉（一台手机配上了）、或剩余不足 1 分钟时，小窗会自己
换一张；也可以点「换一张」。所以配第二台手机直接在手机上删掉旧连接、重新扫当前屏幕上这张
即可，不需要刷新页面或重启 DSH（一张码只能配一台设备）。

### 第 6 步：确认连上了

```bash
curl -s "http://127.0.0.1:<dsh 端口>/mobile-link/status"   # 浏览器打开更省事（要登录态）
```

`"connected": true` + `deviceCount ≥ 1` 就说明两端对上了。

---

## B · 自己开中转（20 分钟）

自建使用仓库内的 Go 实现（`relay-go/`）。

```bash
# 在服务器上（需要 root、Go 1.27 与已装好的 Caddy）
cd relay-go
make build-purego                           # 纯 Go 静态二进制；交叉构建见 deploy/README.md §3
# 按 deploy/README.md §4 安装二进制、build.json 与 dsh-relay-go.service
sudo systemctl enable --now dsh-relay-go

# 建账号 → 给自己铸一个邀请码
/opt/dsh-relay-go/bin/dsh-relay admin --db /var/lib/dsh-relay/state.db \
    account-create --name "<你>"
/opt/dsh-relay-go/bin/dsh-relay admin --db /var/lib/dsh-relay/state.db \
    invite-mint --note "给自己" --count 1 --relay wss://<你的站点>/dsh-link
```

拿到码之后**回到 A 的第 2 步**继续（装连接器 → enroll → 重启 → 扫码）。

Caddy 路由不新增 DNS 与证书：用 `python3 relay/deploy/caddy_splice.py insert /etc/caddy/Caddyfile
relay/deploy/Caddyfile.snippet <你的站点>` 把带标记的片段插进既有站点块，写入前先 `caddy validate`，
失败即回滚；`remove` 按标记原样移除。

运维侧的实时负载、每设备流量与生效中的限额：

```bash
curl -s http://127.0.0.1:8787/stats | python3 -m json.tool | head -40
```

自建时建议开限额（固定带宽共享时防止一个人拖慢所有人）：
`DLP_DEVICE_RATE_KBPS` / `DLP_DEVICE_DAILY_MB` / `DLP_MAX_DEVICES_PER_AGENT`，
取值口径写在 `relay-go/deploy/dsh-relay-go.service` 的注释里。

---

## 配对之后能用什么

两端看到的是**同一个 DSH**：同一批会话、同一条消息流。

| 能力 | 手机侧 | 电脑侧需要 |
|---|---|---|
| 看会话列表、读转写、看工具调用 | ✅ | DSH 在跑 |
| 发消息、打断正在跑的任务 | ✅ | 同上 |
| 回答 agent 的提问卡片 | ✅ | 同上 |
| 发图片进会话（相册/文件） | ✅ | 连接器已登记 |
| 上传文件到会话工作区 | ✅ | 落在 `~/.dsh/inbox/<sessionId>/` |
| 看图、代码高亮、HTML 报告预览 | ✅ | — |
| 锁屏后任务继续跑 | ✅ | 电脑不睡眠 |
| 电脑端**新开**的会话叫醒手机 | ❌ | 需要 APNs，尚未实现 |

权限（只读 / 仅工作区可写 / 完全访问）在电脑上的 DSH 设置里，手机侧只显示当前档位。

---

## 连不上怎么查（按顺序）

| 现象 | 先看这里 | 常见原因 |
|---|---|---|
| 界面里没有「移动端连接」入口 | DSH 是否重启过 | 插件没生效（新装的客户端半边要重启才进图）：`ps` 看 DSH 进程的启动时间 |
| App 显示「电脑离线」 | 电脑侧 `/mobile-link/status` 的 `enroll.registered` | 没登记：回到 A 第 3 步 |
| 状态里 `state: backoff` + `4001 superseded` | 是不是有**第二个** DSH 在跑同一个身份 | 旧进程没退干净，`kill` 掉旧的 |
| 连上但会话列表空 | 电脑上 DSH 里有没有会话 | — |
| 手机一直「连接中」 | `agent.json` 里的 `relayUrl` 与服务端地址 | 登记时填错了中转地址 |
| 邀请码报 `invite/used` | — | 一个码只能用一次，领新的 |
| 手机端功能缺失 | 发布页有没有新版本 | TestFlight 构建过期 |

要在**不打扰**正在运行的连接器的前提下确认它能不能连上：

```bash
dsh-mobile-link --log-level debug --once      # 打印一行 MOBILE_LINK_STATE 就退出
```

`connected: true` 就是通的。**别长时间前台跑**：连接器的身份是唯一的，第二个连上会把 DSH 里
那个顶掉（日志里的 `4001 superseded`），DSH 里那个随后会自己重连。

---

## 卸载 / 换中转

```bash
# 换中转：撤掉旧身份，再重新登记
rm ~/.dsh/mobile-link/agent.json
dsh-mobile-link enroll --invite <新邀请码> --relay wss://<新站点>/dsh-link

# 卸载连接器
dsh plugin --profile web remove dsh-plugin-mobile-link
```

手机侧在「设置 → 已配对的设备」里可以撤销某台设备；撤销后那台手机需要重新配对。
