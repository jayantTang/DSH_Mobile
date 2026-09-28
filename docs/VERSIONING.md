# 版本与部署策略

> 面向：维护者与部署方 · 状态：stable · 最近核对：2026-09-20
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
├── relay/                         公网中转服务（Python）
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
| 服务器 `/opt/dsh-relay/` | 中转服务 | `relay/deploy/deploy.sh` |
| 服务器 `/ios/` | OTA 安装包与 manifest | `scripts/release/deploy-ota.sh` |

判定原则：**能由仓库内容重新生成的，不进仓库；含密钥或机器状态的，绝不进仓库。**

## 二、三个部署目标与各自的发布方式

| 部署目标 | 代码来源 | 发布命令 | 生效方式 | 版本标识 |
|---|---|---|---|---|
| **iOS App** | `ios/DSHMobile/` | `./scripts/release/deploy-ota.sh` | 手机 Safari 装 OTA | `CFBundleVersion`（时间戳） |
| **电脑端连接器 + 插件** | `plugins/` | `./scripts/install/install-plugin.sh` | **重启 DSH** | 无（见缺口 1） |
| **公网中转** | `relay/` | `relay/deploy/deploy.sh` | 服务重启 | `/healthz` 的 `version` |
| skill | `skills/` | `./scripts/install/install-skills.sh` | 重启 DSH | 无 |

## 三、兼容性约束（最重要）

三者通过 DLP 协议对话，**独立升级，因此必须明确什么可以单独升、什么必须一起升**。

**DLP 协议版本**：`/healthz` 返回 `{"ok":true,"version":1}`，连接器在握手中声明
`protocolVersion`。

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

## 四、发布流程（建议固定下来）

```
1. 改代码（仓库内）
2. 跑单测：DSHKit (swift test) + plugins/* (npm test) + relay (pytest)
3. 仿真器里实跑逐屏核对（用例层已删除，等用户重新设计）
4. 按需部署：
   - 只改了 App      → ./scripts/release/deploy-ota.sh
   - 改了连接器/插件 → ./scripts/install/install-plugin.sh 然后**重启 DSH**
   - 改了中转        → relay/deploy/deploy.sh
5. 真机验证（手机端）
6. 记一行三方版本（App / 连接器 / 中转协议），发布记录在部署方内部维护
7. git commit
```

**必须遵守**：连接器或插件改动后**不重启 DSH 等于没生效**。这一条已经导致过一次
整轮无效排查——运行中的连接器把新方法的调用转发给 Host 并返回 404，看起来像代码错误。

## 五、版本号约定

| 部件 | 编号方式 | 说明 |
|---|---|---|
| iOS App | `yyyyMMddHHmm`（UTC） | 由 `deploy-ota.sh` 自动打；单调递增，iOS 才肯装 |
| 连接器 / 插件 | 语义化 `0.x.y` | 写在各自 `package.json`；连接器把它当 `SERVER_VERSION` 回显给 App（缺口 1 已解决）。线上真值以 `npm view <name> version` 为准 |
| 中转 | 整数协议版本 + 部署时间 | `/healthz` 暴露协议版本 |

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
