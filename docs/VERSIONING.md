# 版本与部署策略

> 面向：维护者与部署方 · 状态：stable · 最近核对：2026-10-17
>
> 日期只表示最后一次人工过目，**内容是否仍然成立以本文件内的 `文件:行` 引用与
> 第六节那几条命令为准**（见「六、本篇的结论怎么自己验」）。

本项目的代码分布在**一个仓库**里，但运行时会**部署到三个地方**。三者独立发布、
必须互相兼容——这是版本策略要解决的核心问题。

## 一、代码在哪：仓库是唯一事实来源

```
19_dsh_iosapp/                     ← git 仓库（唯一的源码）
├── ios/DSHMobile/DSHKit/               DSH 客户端协议层（Swift）
├── ios/DSHMobile/                 原生 iOS App（SwiftUI）
├── plugins/
│   ├── mobile-link/               电脑端连接器（DLP v1 实现）
│   └── send-image/                send_image 工具插件
├── skills/send-image/             skill 源码
├── relay-go/                      公网中转服务（Go）
├── scripts/                       安装 / 部署 / 测试脚本
└── docs/                          架构、协议、用例、本文件
```

**以下内容不在仓库里，也不应该进去**——它们是派生产物或本机状态：

| 位置 | 是什么 | 由谁生成 |
|---|---|---|
| `~/.dsh/skills/send-image/` | skill 的已安装副本 | `scripts/install/install-skills.sh` |
| `~/.dsh/profiles/web/package.json` | 插件注册（bundles 列表） | `scripts/install/install-plugin.sh` |
| `~/.dsh/mobile-link/agent.json` | 中转身份与密钥 | 配对流程 |
| `~/.dsh/inbox/<会话id>/` | 手机发来的文件 | 运行时产生 |
| 服务器 `/opt/dsh-relay-go/` | 中转服务（Go 单二进制） | 安装步骤见 `relay-go/deploy/README.md` §3–§4 |
| 服务器 `/ios/` | OTA 安装包与 manifest | `scripts/release/deploy-ota.sh` |

判定原则：**能由仓库内容重新生成的，不进仓库；含密钥或机器状态的，绝不进仓库。**

## 二、三个部署目标与各自的发布方式

| 部署目标 | 代码来源 | 发布命令 | 生效方式 | 版本标识 |
|---|---|---|---|---|
| **iOS App** | `ios/DSHMobile/` | `./scripts/release/deploy-ota.sh` | 手机 Safari 装 OTA | `CFBundleVersion`（时间戳） |
| **电脑端连接器 + 插件（本机）** | `plugins/` | `./scripts/install/install-plugin.sh` | **重启 DSH** | 各自 `package.json` 的语义化版本，连接器把它当 `SERVER_VERSION` 回显给 App |
| **电脑端连接器 + 插件（发给别人）** | npm 上的同名包 | `scripts/release/publish-plugins.sh --publish` | 对方 `dsh plugin add` | 同上；线上真值以 `npm view <name> version` 为准 |
| **公网中转** | `relay-go/` | `relay-go/deploy` 安装，或 `switch.sh --to-go` | 服务重启 | `/healthz` 的 `version`（协议版本）与 `relayVersion`（`go-X.Y.Z`）+ `build`（commit/部署时刻） |
| **信件服务** | `mail/` | `mail/deploy/deploy.sh` | 服务重启 | 该服务 `/healthz` 的 `version`（同一个构建号口径） |
| skill | `skills/` | `./scripts/install/install-skills.sh` | 重启 DSH | 无 |

安装页除了最新版，还列出**前两个旧版本**作为回退入口：最新版装不上、或一打开就退出时，
用旧版本覆盖安装即可回到能用的状态（覆盖安装保留本机数据，不必先卸载）。服务器上因此保留
最近三份版本化产物（`.ipa`、manifest、图标成套），由 `deploy-ota.sh` 每次发布后自动裁剪；
份数用 `DSH_OTA_KEEP` 调整，默认为 3。改安装页或回退清单时用
`./scripts/release/deploy-ota.sh --dry-run` 在本机生成页面自检，不碰服务器。

## 三、兼容性约束（最重要）

三者通过 DLP 协议对话，**独立升级，因此必须明确什么可以单独升、什么必须一起升**。

**DLP 协议版本**：`/healthz` 返回 `{"ok":true,"version":1}`，连接器在握手中声明
`protocolVersion`。

**版本号口径**（owner 2026-10-17 定）：**有 npm 注册版本的三件**（连接器、send-image、
doubao-image）继续语义化 `0.x.y`，每次发布递增——包不可变，版本号就是发布标识；
**没有注册表的**（iOS App、公网中转、信件服务、Web 客户端）一律用构建号
`yyyyMMdd.HHmm`（北京时间），与 App 的 `CFBundleVersion` 同口径，一眼能看出发布先后；
**DSH 宿主**沿用上游版本，只读。skills 随所属插件版本，不单独编号。

**四段版本各自的出口**（只走控制帧，业务帧不重复携带）：

| 部件 | 谁产生 | 手机怎么知道 | 中转怎么知道 |
|---|---|---|---|
| iOS App | `CFBundleShortVersionString` + `CFBundleVersion` | 设置「关于」 | 每次连接 `_link/hello` 的 `clientVersion`/`clientBuild` → `devices.appVersion` |
| 连接器 | `package.json`（`SERVER_VERSION`，读文件、不读 `require` 缓存） | `_link/hello` 的 `serverVersion` → 「关于」 | `hostStatus.info.version` → `agents.connectorVersion` |
| DSH 宿主 | 进程环境 `DSH_CLIENT_VERSION` | `_link/hello` 的 `hostVersion` → 「关于」 | `hostStatus.info.hostVersion` → `agents.hostVersion` |
| 公网中转 | 部署构建号 `yyyyMMdd.HHmm`（`deploy.sh` 生成，写进 `build.json`） | 中转发的 `hostStatus.info.relayVersion` → 「关于」 | `/healthz` 的 `relayVersion` + `build` |

中转在**值变化时**才写一次库（`agents.versionsAt` 是最后一次上报时刻）；连接器只在每次
链路建立时写一行流水（`link.open` 的 `serverVersion`/`hostVersion`）。排障时
`dsh-relay admin device-list` 一行就能看到「手机 / 连接器 / DSH」三段版本。

宿主版本只有一条来源：DSH 进程环境里的 `DSH_CLIENT_VERSION`（桌面版由原生启动器注入）。
没有设这个变量的宿主，连接器报 `null`，App 如实显示「未上报」——不拿连接器版本或其他
文件去猜，猜错比空着更难查。

规则：

1. **中转的协议版本不兼容变更 → 必须同时升级中转和连接器**，并考虑 App。
2. **连接器新增能力**（如文件接收）→ 只要走已有帧类型，**App 可以后升**；
   旧连接器会把新调用转发给 Host 并得到 404，App 显示错误而非崩溃。
   这是当前文件功能的实际状态，属于**优雅降级**。
3. **App 新增能力**（如新的界面）→ 与连接器无关，可独立升。
4. **不允许**：让 App 依赖某个「新连接器才有的方法」而不做能力探测。

### 当前的真实缺口

三态：**已解决**（附 `文件:行`，下一个人不必重查）/ **仍然存在** / **无法核对**（附原因）。

| 缺口 | 状态 | 依据 |
|---|---|---|
| **1. 连接器没有版本号** | **已解决** | `plugins/mobile-link/lib/hello.js:25-33` 的 `SERVER_VERSION` 直接读 `package.json`，`_link/hello` 回传给 App |
| **2. App 不做能力探测** | **已解决** | `ios/DSHMobile/DSHKit/Sources/DSHKit/LinkHandshake.swift:44-58` 的 `Capability` 常量；`ConnectionStore.swift:212` 的 `supports()`；使用点 `Features/Chat/Composer.swift:235`、`Features/Files/GitModel.swift:85,102`。能力全集与三端一致性由 `npm run check:contracts` 的第 ⑤ 段守住 |
| **3. 三方版本无对应关系记录** | **无法核对** | 记录在部署方内部维护、不随仓库发布，所以本仓库的任何断言都无法验证它是否在记。这一条只能在部署方那边核 |
| **4. 无「一键装齐」入口** | **已解决** | `scripts/install/install-all.sh`（skill + 插件 + 提示重启，第三步逐个核对接了哪些包） |
| **5. ~~直连与中转能力不同~~** | **已关闭** | 已决策只保留中转一条路，见 `docs/PAIRING.md`；直连退化为 DEBUG-only 测试通道 |
| **6. 连接器与 DSH 版本在中转查不到** | **已解决** | 连接器在控制帧 `hostStatus` 里报 `version`/`hostVersion`（`plugins/mobile-link/lib/link.js:sendHostStatus`），中转按 agent 记 `agents.connectorVersion`/`hostVersion`（`relay-go/internal/hub/notify.go:noteAgentVersions`）；`dsh-relay admin device-list` 与设备行一起输出 |
| **7. 中转自身没有版本标识** | **已解决** | `/healthz` 返回 `relayVersion`/`build`（读 `/opt/dsh-relay-go/bin/build.json`），设备经 `hostStatus.info.relayVersion` 在 App「关于」里看到 |
| **8. Web 客户端版本只在配对时写一次** | **仍然存在** | Web 端每次连接不发 `_link/hello`（本机 journal 记 `missing:["hello"]`），中转的 `devices.appVersion` 停在配对时的 `0.1.0`。修法在 Web 仓库：按 §三 的表发握手字段即可，本仓库无需改动 |

## 四、发布流程（建议固定下来）

```
1. 改代码（仓库内）
2. 跑单测：DSHKit (swift test) + plugins/* (npm test) + relay-go (make test) + relay (pytest，回滚实现)
3. 仿真器里实跑逐屏核对（用例层已删除，等用户重新设计）
4. 按需部署：
   - 只改了 App      → ./scripts/release/deploy-ota.sh
   - 改了连接器/插件 → ./scripts/install/install-plugin.sh 然后**重启 DSH**
   - 要把插件发给别人 → 升各自 package.json 的版本，scripts/release/publish-plugins.sh --publish
                        （发之前先 --staged 看 npm 的暂存队列，同名旧暂存会挡住发布）
   - 改了中转        → 升 `relay-go` 版本号、重建二进制、重启 `dsh-relay-go`，并打 `relay-vX.Y.Z` tag
5. 真机验证（手机端）
6. 记一行三方版本（App / 连接器 / 中转协议），发布记录在部署方内部维护
7. git commit
```

**必须遵守**：连接器或插件改动后**不重启 DSH 等于没生效**。这一条已经导致过一次
整轮无效排查——运行中的连接器把新方法的调用转发给 Host 并返回 404，看起来像代码错误。

## 五、版本号约定

| 部件 | 编号方式 | 说明 |
|---|---|---|
| iOS App | `yyyyMMdd.HHmm`（**北京时间**） | 由 `deploy-ota.sh` 自动打（规则与用例在 `scripts/release/ota-version.mjs`）：两段整数、都在 `CFBundleVersion` 上限内（早先那个 12 位时间戳越界，iOS 会静默不装，看起来像「必须先删掉旧 App」）；拿线上 `version.json` 的号当下界保证严格递增；安装页、`version.json`、CHANGELOG 与提交信息一律北京时间 |
| 连接器 / 插件 | 语义化 `0.x.y` | 写在各自 `package.json`；连接器把它当 `SERVER_VERSION` 回显给 App（缺口 1 已解决）。线上真值以 `npm view <name> version` 为准 |
| 中转 | 语义化 `go-X.Y.Z` | `/healthz` 暴露 `relayVersion` 与 `build`；安装时写 `/opt/dsh-relay-go/bin/build.json`（版本 + commit + 部署时刻），启动日志也打一行。Go 版按发版节奏打 `relay-vX.Y.Z` tag，构建号即发布标识 |
| 信件服务 | 部署构建号 `yyyyMMdd.HHmm`（与中转同一口径） | `mail/deploy/deploy.sh` 写 `/opt/dsh-mail/build.json`；该服务 `/healthz` 的 `version` 读它 |

## 六、本篇的结论怎么自己验

第 3 行的「最近核对」日期只表示**最后一次人工过目**，不表示内容仍然成立——会漂的东西
交给命令，而不是交给一个越放越假的日期。下面几条不依赖网络，`npm run` 的那几条在
CI 的 `docs` job 里每次都会跑：

```bash
npm run check:docs        # 结构、口吻、链接与裸路径
npm run check:secrets     # 跟踪文件里没有本机真值
npm run check:contracts   # 契约单一来源：DLP 向量 / 安装阶梯 / 调试钩子 / 能力词表 / host 基线
npm run check:i18n        # 本地化双向缺键、硬编码、未本地化绑定
npm view dsh-plugin-mobile-link version   # 上面那张状态表的连接器版本（需要网络）
```

缺口表里每条「已解决」都附了 `文件:行`——**核对就打开那个文件看那一行**，不要以日期为准。

## 七、待办

1. ~~给连接器加版本号并在 `status` 中回显~~ 已解决（`plugins/mobile-link/lib/hello.js:25-33`）
2. ~~连接器声明 `capabilities`，App 据此显示/隐藏文件入口~~ 已解决（`LinkHandshake.swift:44-58` + `ConnectionStore.supports()`）
3. **仍然存在**：建立三方版本组合的发布记录——记录在部署方内部维护，不进仓库（缺口 3）
4. ~~新建 `scripts/install/install-all.sh`~~ 已解决
5. ~~决定直连模式的文件发送~~ 已关闭：只保留中转，直连退化为 DEBUG-only 测试通道
