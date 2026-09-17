# 版本与部署策略

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

| 缺口 | 风险 | 建议 |
|---|---|---|
| **1. 连接器没有版本号** | 无法判断本机装的是哪一版；排查只能靠文件时间戳 | 在插件 `package.json` 记 `version`，并在 `mobile-link/status` 里回显 |
| **2. App 不做能力探测** | 文件发送在旧连接器下只是报错，用户不知道「升级连接器就能用」 | 连接器在 `status` 里声明 `capabilities`，App 据此决定是否显示文件入口 |
| **3. 三方版本无对应关系记录** | 出问题时无法复现「当时的组合」 | 每次发布记一行：App 版本 / 连接器版本 / 中转版本（发布记录在部署方内部维护，不随仓库发布） |
| **4. 无「一键装齐」入口** | 容易漏装（实际发生过：改了连接器但没重启 DSH，白排查一轮） | 加 `scripts/install/install-all.sh`，串起 skill + 插件 + 提示重启 |
| **5. ~~直连与中转能力不同~~** | 已决策：**只保留中转一条路**，见 `docs/PAIRING.md` | 从 App 界面移除直连入口；直连退化为 DEBUG-only 的测试通道 |

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
| 连接器 / 插件 | 语义化 `0.x.y`（**待落地**） | 目前是 `0.1.0` 且从不递增 |
| 中转 | 整数协议版本 + 部署时间 | `/healthz` 暴露协议版本 |

## 六、待办

1. 给连接器加版本号并在 `status` 中回显
2. 连接器声明 `capabilities`，App 据此显示/隐藏文件入口
3. 建立三方版本组合的发布记录（在部署方内部维护，不进仓库）
4. 新建 `scripts/install/install-all.sh`
5. 决定直连模式的文件发送：补 HTTP 上传路由，或在 App 中明确提示不可用
