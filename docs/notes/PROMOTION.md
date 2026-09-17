# 发布与分发清单

代码写完不等于有人知道。这份清单是「让生态里能找到这个项目」要做的事，按性价比排序。
**凡是需要 GitHub token、npm 登录或某个平台账号的操作都标了「要你」——剩下的可以交给 AI 做。**

## 一、仓库元数据（GitHub 网页直接改，两分钟；用 API 改则需要 token）

**About 里的 Description**（现在是 `DSH Mobile App (iOS)`，等于没写；GitHub 搜索权重全在这）：

```
在 iPhone 上远程使用电脑的 DeepSeek Harness：WSS 经公网中转，4G/5G 可用，电脑不需要公网 IP。Native iOS client for remote DSH sessions.
```

**Topics**（生态的硬性约定：DSH 官方要求插件仓库带 `#dsh`，awesome 列表才会索引到）：

```
dsh  deepseek-harness  ios  iphone  swiftui  remote-control  self-hosted  agent  developer-tools
```

**Homepage**：可留空，或指向 `docs/ARCHITECTURE.md` 的 GitHub 页面地址（不要填中转真实地址）。

## 二、进生态目录（单点收益最大）

### 1. `Dominic789654/awesome-deepseek-harness`（主目录，340 star）

- 位置：`UI / Clients` 一节，该节现在只有 `everettjf/dsh-ios` 一个 iOS 项目。
- 先确认本仓库已带 `dsh` topic，再提 PR。
- 条目（一行，照抄；列表里其他条目的口径是「`名字` — 一句话」，中英混排）：

```
- [jayantTang/DSH_Mobile](https://github.com/jayantTang/DSH_Mobile) — 原生 iOS 客户端 + 电脑侧连接器 + 公网中转：手机不用公网 IP、4G/5G 就能连上电脑上的 DSH，同一批会话与同一条消息流。Native SwiftUI client, a DSH connector plugin, and a self-hosted relay (Python/aiohttp).
```

### 2. `Anil-matcha/awesome-dsh-plugin`（1013 star）

同样一行，放进客户端/UI 相关小节（先看一眼它现有的分区名）。

### 3. `deepseek-ai/awesome-deepseek-agent`（官方，6094 star）

**要你**：官方列表对收录口径更严，通常只收 agent/harness 集成。建议先开 issue 问一句
「远程客户端类的是否收录」，别直接提 PR。

### 4. PR 正文模板

目标仓库的 PR 描述框里贴这一段（条目本身放它 README 的列表里）：

```markdown
### 这个项目做什么

把电脑上的 DSH 装进手机：原生 iOS 客户端 + 电脑侧连接器（DSH 插件）+ 可自建的公网中转。

和已有移动端方案的区别在**连接方式**：不需要公网 IP，手机在 4G/5G 上直接连自己电脑的
DSH；不依赖 Tailscale 之类的组网，也不用在手机上跑一个 DSH 本体。中转只做鉴权与转发，
不解析会话内容，可以自建（`relay/deploy/deploy.sh` 幂等安装）。

- 仓库：https://github.com/jayantTang/DSH_Mobile
- 协议：`docs/RELAY-PROTOCOL.md`（自研 DLP v1）、`docs/DSH-PROTOCOL.md`
- 测试：协议层 58 项、连接器 104 项、中转 107 项，CI 在干净仓库上跑；clone 下来即可
  `swift test` / `npm test`
```

## 三、npm 发布（**要你**：本机 npm 未登录，且 registry 指向 npmmirror）

生态的安装习惯是 `dsh plugin add <名字>`，挂到 npm 之后才等于「可安装」。
三个插件包（`plugins/mobile-link`、`plugins/send-image`、`plugins/doubao-image`）
发布前要补：`license`、`repository`、`files`、`description`、`keywords`（含 `dsh`），
以及各自 README 的安装段。**发之前确认包名没被人占。**

## 四、内容投放（做完上面三节再发，否则点进来看到 0 star 0 图会跑）

**要你**：账号、语气、信誉都是你的，AI 替不了。可以交给 AI 写的部分：

- 一篇有一手数据的文章，而不是「我做了个 App」。能写、别人写不出来的素材：
  - 链路与协议：为什么中转是透明的 JSON 转发、DLP v1 的帧类型与背压设计
  - **为什么最后砍掉了 P2P、只保留中转**（容量与代价的实测分析：这是一篇好文章，
    大多数同类项目写的是「我实现了 P2P」）
  - 具体数字：会话快照单帧 686 KB、图片 base64 多 33%、上行 192 KB 分块让 20 MB 文件
    至少 15 秒、中转单核 37 万帧/秒
- 渠道：V2EX、Linux.do、掘金 / 少数派（中文优先——README 与文档都是中文）

## 五、只能由人来做的两件事

1. **发帖与回复**（上面第四节），以及以你的身份在 issue 里回答问题。
2. **让真人下载试用**。宣传带来的是点击，试用才带来 star：现在别人 clone 下来默认
   连不上任何中转（`relay.example.com` 是「未配置」哨兵），要先自建中转 + Caddy +
   admin 注册 + Xcode 构建。**在发帖之前先决定这条路径怎么走**：
   - 提供公共中转实例（免费额度），或
   - 提供 TestFlight 安装包，或
   - 至少给一个 `curl | bash` 的一键自建脚本。

## 六、进度

- [x] README 首屏：卖点、两张配图、合成会话说明
- [x] 可发布的合成截图脚本 `scripts/dev/demo-session.mjs` + 用例 `TC-DEMO-01`（走中转通道截）
- [x] 本文档（元数据、条目、PR 模板、渠道）
- [ ] 仓库 Description / Topics / Homepage（两分钟，或给 token 由 AI 改）
- [ ] 三个 awesome 列表的收录
- [ ] npm 发布三个插件包
- [ ] 一键自建中转脚本
- [ ] 文章与投放

## 附：还没进 README 的素材

- **会话列表**那张图暂时不能用：列表按时间排，合成会话排在真实会话下面，真截下来会把
  用户的真实项目名拍进去。要拍它得先解决「按项目分组时把 demo 组排到前面」这件事。
- **工作区「变更」页**：分段控件在自动化里点不动（`label:变更` 与按比例点都试过，事件发了
  但界面不切换），所以没有 diff 配图。要那张图得先给它加无障碍标识或 DEBUG 钩子。
- **转写页拍不到「最终答复」**：这个容器在模拟器里滚不动——给 `chat.transcript` 发滑动会抛
  "Pointer events are not supported for this device"（进程级异常，整轮直接 ERROR），
  `scroll(byDeltaY:)` 也一样。所以首屏那张图只有提问 + 工具卡片。要拍到结论，
  得先让这个容器能滚（或给转写加一个「跳到底部」的自动化钩子）。
- **演示 GIF**（提问 → 电脑跑 → 手机看到结果）：`xcrun simctl io … recordVideo` 可以录，
  但需要一轮约 30 秒的真实 agent 交互并按时间轴裁剪，还没做。
