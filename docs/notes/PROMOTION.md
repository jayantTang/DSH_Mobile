# 发布与分发清单

代码写完不等于有人知道。这份清单是「让生态里能找到这个项目」要做的事，按性价比排序。

**先看清楚这个生态长什么样（2026-09-17 实测，不是估计）**：

| 渠道 | 体量 | 怎么进 | 门槛 |
| --- | --- | --- | --- |
| [`dsh-plugin-radar`](https://github.com/AdamPlatin123/dsh-plugin-radar) | 1470 star，21k+ 候选仓，13k+ 次 k8s 实测，每 6 小时快照 | **加 `dsh-plugin` topic → 8 小时内自动收录**；或 PR 到它的 `PLUGINS.md` | topic 免费；PR 要 fork |
| [`Oh-My-DSH`](https://github.com/like-study1/Oh-My-DSH) | 86 star，每 4 小时自动同步 `dsh-plugin` topic | 同上，纯自动 | 无 |
| [`awesome-deepseek-harness`](https://github.com/Dominic789654/awesome-deepseek-harness) | 339 star | PR 到 `UI / Clients` 一节 | 一个 PR |
| [Anil-matcha/awesome-dsh-plugin](https://github.com/Anil-matcha/awesome-dsh-plugin) | 1013 star | PR 到 `### Remote Access & Mobile` | 一个 PR |
| npm | 安装路径 | `npm publish` | 要登录 |
| V2EX / Linux.do / 掘金 | 流量 | 发帖 | 要你出面 |

> **注意**：原来那份 `AdamPlatin123/awesome-dsh-plugins`（清单仓）已经**合并进 `dsh-plugin-radar`**，
> 登记表就是它的 `PLUGINS.md`，分类共 13 类，远程客户端属 `📡 远程渠道`。
> 雷达还有一份人工策展的精选榜，**门槛是 ≥15 star**（智力增强类豁免）——这是第一个值得追的数字。

## 一、仓库元数据（**要你**：GitHub 网页直接改，两分钟）

**About 里的 Description**（现在是 `DSH Mobile App (iOS)`，等于没写；GitHub 搜索权重全在这）：

```
在 iPhone 上远程使用电脑的 DeepSeek Harness：WSS 经公网中转，4G/5G 可用，电脑不需要公网 IP。Native iOS client for remote DSH sessions.
```

**Topics**（`dsh-plugin` 是硬约定，决定雷达与 Oh-My-DSH 能不能自动发现你）：

```
dsh  dsh-plugin  deepseek-harness  ios  iphone  ipados  swiftui  remote-control  self-hosted  agent  relay  websocket
```

同一份文案与话题也写在仓库根的 `package.json` 里（`description` / `topics`），改一处要同步另一处。

**Homepage**：可留空，或指向 `docs/ARCHITECTURE.md` 的 GitHub 页面地址（**不要填中转真实地址**——
那是部署方的资产，也已经因为同样的理由从配图里删掉了）。

> 给 token 的话这一步可以脚本化（`gh` 没装，只能走 API）。不给也行，网页上点两下就是全部工作量，
> 而这是**唯一一步零成本、自动、持续生效**的动作：topic 一加，8 小时内出现在两个自动索引里。

## 二、进生态目录

三个目标都已固化成脚本：**`scripts/release/ecosystem-pr.sh`**。

```bash
scripts/release/ecosystem-pr.sh --list          # 看目标与锚点
scripts/release/ecosystem-pr.sh all             # 生成三个分支（不推送，先看 diff）
scripts/release/ecosystem-pr.sh all --push      # 推到自己 fork 并打印开 PR 的链接
```

脚本会先断言上游文件里的锚点还在（上游每天在动），再插入一行，并把 PR 标题与正文一起提交好。
**唯一的前置**：三个上游仓库各点一次 Fork（没有 token 建不了 fork）。
第一版脚本把条目插进了目录（Contents）而不是正文，所以锚点现在用的是完整标题——这类漂移脚本会直接报错。

- `radar`：`PLUGINS.md` 的 `📡 远程渠道` 表追加一行，标题 `docs: 登记 dsh-mobile-link`
  （PR 模板要求这个标题格式，并要求勾选 *Allow edits from maintainers*）。
  登记的自检清单里有一条「package.json 用 `@dsh-external/*` scope」——**我们的三个包都没有 scope**，
  所以走自动发现路线更稳；提 PR 时在备注里说明这一点，别为了一条清单去改名（改名会毁掉
  `dsh plugin add dsh-plugin-mobile-link` 这个安装路径）。
- `awesome`：`UI / Clients` 一节追加一行（该节现在只有 `everettjf/dsh-ios` 一个 iOS 项目）。
- `plugins`：`### Remote Access & Mobile` 一节追加一行。

### 官方渠道

`deepseek-ai/awesome-deepseek-agent`（6094 star）**要你**：官方口径更严，通常只收 agent/harness
集成。建议先开 issue 问「远程客户端类的是否收录」，别直接提 PR。

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

## 三、npm 发布（**要你**：本机 npm 未登录，registry 指向 npmmirror）

生态的安装习惯是 `dsh plugin add <名字>`，所以 npm 才是真正的「可安装」。三件事已经做完：

- 三个包的元数据补齐（`license` / `author` / `repository` / `homepage` / `bugs` / `keywords` /
  `engines`），去掉了挡住发布的 `private: true`，并把 `README.md` 加进 `files`；
- `plugins/mobile-link` 与 `plugins/send-image` 原本**没有 README**（npm 页面会是空白），已写；
- 发布固化成脚本：**`scripts/release/publish-plugins.sh`**（默认干跑，`--publish` 才真发）。
  它会核对元数据、跑测试、打印**将被打包的文件**，再检查 npm 上是否重名。

```bash
scripts/release/publish-plugins.sh                       # 干跑：元数据 + 测试 + 包内容 + 重名
npm login --registry=https://registry.npmjs.org          # 发布必须用官方源，npmmirror 是只读镜像
scripts/release/publish-plugins.sh --publish
```

已核实：`dsh-plugin-mobile-link`、`dsh-plugin-send-image`、`dsh-plugin-doubao-image`
三个名字在 npmjs 与 npmmirror 上**都还没被占**，且都没有 scope（不会撞上付费组织）。
发完立刻在一台干净机器上 `dsh plugin --profile web add dsh-plugin-mobile-link` 走一次真实安装——
`dsh-plugin add` 接受 npm 包名、`github:owner/repo` 与本地路径，包内容错了只有真实安装才能发现。

## 四、内容投放（做完上面三节再发，否则点进来看到 0 star 0 图会跑）

**要你**：账号、语气、信誉都是你的，AI 替不了。可以交给 AI 写的部分：

- 一篇有一手数据的文章，而不是「我做了个 App」。能写、别人写不出来的素材：
  - 链路与协议：为什么中转是透明的 JSON 转发、DLP v1 的帧类型与背压设计
  - **为什么最后砍掉了 P2P、只保留中转**（容量与代价的实测分析：这是一篇好文章，
    大多数同类项目写的是「我实现了 P2P」）
  - 具体数字：会话快照单帧 686 KB、图片 base64 多 33%、上行 192 KB 分块让 20 MB 文件
    至少 15 秒、中转单核 37 万帧/秒
- **顺手把已有那篇博客稿加上仓库链接与配图**——比写新文章见效快得多，因为稿子已经写完了。
- 渠道：V2EX、Linux.do、掘金 / 少数派（中文优先——README 与文档都是中文）。
  同类项目在这个生态里的现状：`everettjf/dsh-ios` 10 star（3 周）、`dsh-android-app` 12、
  `dsh-remote-mobile` 17、`DSHBox` 24、`deepseek-harness-pocket` 0。**手机端的量级就是这个数**，
  所以别用 star 当唯一指标（见下）。

## 五、只能由人来做的两件事

1. **发帖与回复**（上面第四节），以及以你的身份在 issue 里回答问题。
2. **让真人下载试用**。宣传带来的是点击，试用才带来 star：现在别人 clone 下来默认
   连不上任何中转（`relay.example.com` 是「未配置」哨兵），要先自建中转 + Caddy +
   admin 注册 + Xcode 构建。**这条路的现状、缺什么、怎么做，全部写在
   [`ENABLE-TRIAL.md`](ENABLE-TRIAL.md)**（公共中转今天就能开；TestFlight 缺 Apple
   Distribution 证书，本机只有 Development 身份）。

## 六、进度

已做完（都在仓库里，可复跑）：

- [x] README 首屏：卖点、两张配图、合成会话说明；真实域名与用户名已从配图里拿掉
- [x] 可发布的合成截图脚本 `scripts/dev/demo-session.mjs` + 用例 `TC-DEMO-01`（走中转通道截）
- [x] 仓库根 `package.json`：description / topics / keywords（GitHub 那两栏的文案唯一来源）
- [x] 三个插件包的 npm 元数据与 README；`scripts/release/publish-plugins.sh`（干跑通过，包名未被占）
- [x] 生态目录 PR 固化：`scripts/release/ecosystem-pr.sh`（三个目标各生成一个分支，已本地验过 diff）
- [x] TestFlight 的导出配置 `ExportOptions-appstore.plist`；试用路径与缺口写在 `ENABLE-TRIAL.md`
- [x] 本文档

还要做的（按顺序，前两步之外都需要你的账号）：

- [ ] **给仓库加 topics + 改 description**（网页两分钟；加完 8 小时内自动进两个索引）
- [ ] **三个上游仓库各点一次 Fork**，再跑 `scripts/release/ecosystem-pr.sh all --push` 开 PR
- [ ] `npm login` 后跑 `scripts/release/publish-plugins.sh --publish`
- [ ] 决定公共中转发不发（`ENABLE-TRIAL.md` 第一节；**限额做完再发邀请码**）
- [ ] Apple Developer 会员 → Distribution 证书 → TestFlight（`ENABLE-TRIAL.md` 第二节）
- [ ] 已有博客稿加仓库链接与配图；然后才发帖

## 七、用什么衡量

star 在这个赛道里噪声太大（同类手机端项目最高 24）。按这个顺序看：

1. **中转上的实名设备数**（`admin.py device-list`）——真正装起来的人数；
2. **clone 数**（GitHub Insights → Traffic）——README 与话题是否生效；
3. **`dsh-plugin-radar` 是否收录 / 是否进精选榜**（≥15 star 是门槛）；
4. star。

时间盒：topics + PR + npm 之后给 8 周。8 周内 clone 数没起来，说明问题在「试用路径」而不在
「宣传文案」——那就别再写文章了，去把 TestFlight 或一键自建做出来。

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
