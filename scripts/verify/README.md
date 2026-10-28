# 三级验证渠道

隔离强度 × 被测对象的矩阵与三个可独立调用的渠道。判定口径只有一份：
[`lanes.json`](./lanes.json)；拦截脚本读它，渠道入口也读它。

设计文档：`specs/006-verify-lanes/`（本地过程产物，不在仓库里）。

## 三级各是什么

| 渠道 | 环境 | 能验 | 不能验 |
|---|---|---|---|
| `l1` 同机隔离 | 同一台 Mac、同一份二进制；临时 `HOME`/`DSH_HOME` + 一次性档案 | 宿主起停、插件挂载、连接器与插件单测、端点发现 | 干净机器上的首次启用 |
| `l2` Linux 容器 | Linux guest 里的容器卷，**代码复制进卷** | 协议层纯函数、插件与脚本单测、web 宿主、relay（含真 Caddy） | 官方桌面版（`.app` 跑不进 Linux）、iOS App |
| `l3` 干净环境 | 客体 VM / 真实干净机器 / 干净 CI runner | 干净机器从零启用的整条流程、桌面版宿主 | 每次都跑（成本高）；非交互登录 Apple ID |

渠道 ≠ 通道：端到端结论只能在 `l3` 取得，`l1`/`l2` 的证据不得冒充它。

## 命令

```bash
npm run lane:doctor                            # 三级自检（只报告，不装东西、不拉镜像）
npm run lane:l1                                # 单级自检
npm run lane:l1 -- run --scenario smoke        # 跑一个场景，写证据包
npm run check:lanes -- --changed <file>        # 这次改动必须跑哪几级、缺哪一级
npm run check:lanes -- --changed-from changed.txt --json   # CI 用
```

退出码：`0` 齐备；`1` 缺证据或某级 `blocked`/`fail`；`2` 工具自身错误（矩阵坏、入口漂移）。

## 三级各自的前提与补救

`npm run lane:doctor` 会逐项列出；不可用时按它给的 `nextStep` 做。下面是人做的那几步：

**L2（Linux 容器）**

```bash
brew install colima docker
colima start                      # 默认就是 vz + virtiofs；内存/CPU 见 ~/.colima/default/colima.yaml
sh scripts/verify/l2-vm-setup.sh  # 补镜像源 + 修 VM 的 resolv.conf，然后重启 docker
docker pull node:22-bookworm-slim # 确认拉得动（本机直连 Docker Hub 超时，必须走镜像源）
```

两个坑写在 `test/CAPABILITY-GAPS.md` 的「环境-8」：colima 每次启动会重写
`/etc/docker/daemon.json`（它不支持 `registry-mirrors` 键），而镜像里的 `/etc/resolv.conf`
是悬空链接、dockerd 会去问 `[::1]:53`。所以这两件事每次都靠上面那条脚本补，
doctor 则以 `docker info` 自报为准（不看配置文件，免得得到假结论）。

**L1 · App 逐屏（`ios-transcript-fold`）**

`ios-app` 这一档的正式证据只能来自"仿真器经公网中转跑一条逐屏用例"：

```bash
npm run lane:l1 -- run --scenario ios-transcript-fold
# 用例默认 test/cases/current/03-折叠占位行四态.md；换一份等价用例：
FOLD_L1_CASE=test/cases/example/xxx.md npm run lane:l1 -- run --scenario ios-transcript-fold
然后 npm run check:lanes -- --changed <本次文件>
```

- **前置**：Xcode 命令行工具可用、仿真器已启动（`xcrun simctl boot DSH-Test`）、
  中转已配对、用例文件在本机（`test/cases/*` 被 gitignore，所以"找不到"是常态）。
  缺任何一项场景返回 **blocked**（带 `blockedReason` + `nextStep`），不是 fail。
- **判据**：构建 `BUILD SUCCEEDED` → 用例 `engineVerdict=PASS`、`pixelOk=true`、截图 ≥5 →
  `detail/probe.log` 里没有 `anomaly.unfolded`、出现 `shape=unknown` 与 `shape=folded`、
  `process.unknown.retry` 至少一条非 `resolving` 终态。任一不满足 → **fail**。
- **覆盖边界**：只覆盖"逐屏看得出对错"的那一档（占位行四态、形态词、首帧有没有整块铺开）。
  **不覆盖** D1/D2/D3 的抖动统计——那要在真实长会话上按 25 s 取探针序列，一条用例给不了；
  别把它当成"App 改动全保"。
- **别拿别的场景的 l1 verdict 顶替**：`check:lanes` 按 `lane + status + 新鲜度` 匹配，
  不按 `scenario` 匹配，所以它**拦不住错配**（2026-10-27/28 两次评审踩过：
  用 `ios-link-carrier-lifecycle`、`mail-tests` 的旧证据顶 App 逐屏结论）。
  要真正防错配得给 `verdict.scenario` 与 `subjects` 建映射，属另立项。

**L3（干净环境，在真实环境里跑）**

三种实现都算，任选其一（owner 2026-10-08 决定：不要求本机装虚拟机）：

```bash
# a) 本机客体 VM（最方便，但吃磁盘：镜像 ~25.5 GB 压缩 / 50 GB 稀疏盘）
brew install cirruslabs/cli/tart
tart clone <干净 guest 模板> dsh-lane-l3      # 一次性实例，跑完删掉
npm run lane:l3 -- run --scenario onboarding-from-scratch

# b) 真实干净机器（保真最好：能带真机、走真实网络）
#    在那台机器上装本仓库后直接跑同一条命令

# c) 干净 CI runner（macos-26，Xcode 预装；本地零磁盘，但只有仿真器）
```

本机没装 VM 工具时 `lane:doctor` 会如实报阻塞——这不是"这一级不存在"，而是"本机这条实现不可用"；
此时要么用 b/c，要么在改动记录里写 `L3: 未跑 — <理由>`（门禁会原样打印，不许静默跳过）。

## 纪律

- **不碰真实数据**：`l1` 只读真实档案当模板（`cpSync` 复制到临时目录），跑完用
  `agent.json` 的 sha256 + mtime 对照证明没动过，写进 `verdict.json` 的 `isolation.proof`。
- **复制档案会弄断插件的相对符号链接**（已踩）：档案里的 `node_modules/dsh-plugin-*` 是相对仓库的
  链接，复制到临时目录后就断了；而 `existsSync` 对断链返回 `false`，用它会**静默跳过**改写，
  现象是"宿主起得来、但三个插件全被 skipping，等到超时"。判"链接在不在"必须用 `lstatSync`，
  改写后指向仓库的绝对路径。
- **渠道不可用要报 blocked**，不带 `blockedReason` + `nextStep` 的证据包直接判不合法
  （CI 里 Caddy 装不上导致 skip 反而更绿的教训）。
- **证据新鲜度是机械判据**：证据包的 mtime 必须不早于被改文件里最新的那个，旧结论不能顶账。

## 证据

`.lanes/runs/<lane>/<run-id>/verdict.json`（`.lanes/` 已 gitignore），四态判定
`pass` / `fail` / `blocked` / `not-run`，结构与校验见
`specs/006-verify-lanes/contracts/verdict.schema.json`。

## 调矩阵

`lanes.json` 里每个被测对象用 `globs` 把改动文件映射到自己；一个文件命中多个对象时
**取并集**（宁可多跑一级）。当前有意设成"改 `plugins/mobile-link/lib/index.js` 或安装脚本
要跑 `l3`"——它同时影响两个宿主，只有干净机器能给出可信结论。想放宽就改矩阵，
不要在 `check-lanes.mjs` 里加第二份口径。
