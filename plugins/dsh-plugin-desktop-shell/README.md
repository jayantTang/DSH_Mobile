# DSH macOS Shell

把浏览器里的 DSH 变成**一个真正的 Mac 应用窗口**，并且带**可点击的一键升级提醒**。

由两个互相独立的部分组成，任一部分坏掉都不影响另一部分：

| 部分 | 位置 | 作用 |
|---|---|---|
| **DSH.app** | `/Applications/DSH.app`（源码 `macos/main.swift`） | 原生 macOS 窗口（WKWebView）。双击图标即启动：自己拉起 `dsh web`，解析它打印的带 token 地址并加载整个 GUI。不需要在终端敲任何命令。 |
| **dsh-plugin-desktop-shell** | 本目录（官方 profile bundle，源码入口 `lib/index.js`） | 提供 `GET /desktop-shell/status`（本地版本 / npm 上可用版本）、`POST /desktop-shell/upgrade`（一键升级）、`/open-app`、`/open-config` 四个路由；并把一段自包含的 UI 注入到网页：**常驻的版本号**（就在侧边栏「设置」按钮里、“设置”两个字右边）+ **仅在有更新时出现**的升级浮窗；另写 `endpoint.json`（交接）与 `app.pid`（App 租约）。 |

## 长期位置

整套东西（插件 + macOS App 源码）都住在 DSH 官方的 profile 插件目录里，**没有单独的项目目录**：

```
~/.dsh/profiles/web/plugins/dsh-plugin-desktop-shell/    ← 插件包根目录（唯一源码位置）
├── package.json         # dsh.bundle.patch → cordis.patch.yml
├── cordis.patch.yml     # bundle 层：insert 主机插件（name 相对本文件锚定）
├── lib/index.js         # 主机插件：四个路由 + 注入的网页 UI
├── macos/               # DSH.app 那一半（Swift + 构建/安装脚本）
└── README.md / docs/REPAIR.md
```

它以一个 **profile bundle** 的形式注册进 `~/.dsh/profiles/web`：`package.json` 的 `dependencies` 是 `link:plugins/dsh-plugin-desktop-shell`（pnpm 的符号链接，源码仍在本目录），`dsh.profile.bundles` 里多一项 `dsh-plugin-desktop-shell`。以后要改就直接改这里，改完热加载（App 源码改完重跑 `macos/install.sh` 重装 App 即可）。

## 安装

```bash
bash ~/.dsh/profiles/web/plugins/dsh-plugin-desktop-shell/macos/install.sh
```

做四件事：

1. 用 `swiftc` 构建 `macos/build/DSH.app` 并复制到 `/Applications/DSH.app`（`/Applications` 不可写时退到 `~/Applications`）；
2. 写默认配置 `~/.dsh/desktop-shell/app.json`（已存在则保留）；
3. 用官方的 `dsh plugin --profile web add link:plugins/dsh-plugin-desktop-shell` 把本包注册成 profile bundle（自动装进 `node_modules` 并追加到 `dsh.profile.bundles`），同时清掉旧版本留在 `cordis.patch.yml` 里的 managed block；因为 web profile 是 `patchReload: live`，**正在运行的 DSH 会热加载补丁**；
4. 起一个临时实例（端口 0）自检 `/desktop-shell/status` 是否返回 401（未认证即拒绝 = 插件已加载且被 DSH 自己的信任围栏保护）。

前置条件：官方插件管理走 pnpm，没装的话先 `npm install -g pnpm`。

常用变体：`--no-verify`（跳过自检）、`--no-app`（只装/重装插件）、`--no-plugin`（只装 App）。

## 使用

- **打开**：启动台 / 聚焦搜索 / 应用程序里点 `DSH`，或把它拖进程序坞。App 会自己起服务，退出 App 时它启动的服务一并退出。
- **窗口内**：标准 Mac 窗口，支持 ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z（⇧⌘Z 重做）编辑快捷键、⌘Q 退出、⌘R 重载、⌘+ / ⌘- 缩放、⌘F 全屏；外链自动用默认浏览器打开。
  - 这些编辑快捷键靠「编辑」菜单里的标准项（响应链 → WKWebView）才能生效：macOS 只会把 ⌘C 这类按键先交给主菜单，没有对应菜单项时网页根本收不到，表现就是“按了没反应”。改菜单请保留这一节。
- **菜单**：
  - `编辑 → 撤销 / 重做 / 剪切 / 复制 / 粘贴 / 全选`
  - `DSH → 检查更新…`：原生弹窗对比本地版本和 npm 上的版本，点“立即升级”即在后台执行 `npm install -g @deepseek-ai/dsh@<version>`，完成后面板提示“立即重启”。
  - `文件 → 在浏览器中打开` / `重启 DSH 服务` / `停止后台 DSH 服务并退出`
  - `DSH → 打开配置文件夹` / `打开日志`
- **版本号常驻**：侧边栏「设置」按钮里、“设置”两个字右边有一个小胶囊 `DSH <当前版本>`，平时就只有这一处 UI，不占地方、不打扰（侧边栏收起成图标栏时自动隐藏）。
  - 胶囊有描边、悬停变亮，点一下会在上方弹出面板：当前版本 / 跟随通道 / 新会话默认权限，加 `检查更新`、`在桌面应用中打开`、`配置文件夹` 三个按钮；同一行给出结论（`已是最新版本：x（通道 latest）` 带时间戳，或具体失败原因）。检查期间按钮显示「检查中…」至少 450ms，避免“点了看不出反应”。
  - 点击判定绑在 document 的捕获阶段，并额外接受“坐标落在胶囊矩形内”的点击：胶囊住在 DSH 自己的「设置」按钮里，React 可能在按下与抬起之间替换这个节点，那样浏览器会把 click 交给底下的按钮（表现就是点了没反应 / 误开设置弹窗）。改这段前先读 `lib/index.js` 里的 `aimedAtBadge()`。
- **升级浮窗只在有得升时出现**：只有 npm `latest` 比本地新时，右下角才出现 `DSH 有新版本 vX` + 「立即升级 / 稍后」；升完或点「稍后」即消失。预发布通道（`next`/`alpha`）默认**完全不出现、不提醒**。
- **点那个版本号**会展开一个小面板：当前版本 / 跟随的 tag / 新会话默认权限、检查更新、在桌面应用中打开、配置文件夹。点它只会开这个面板，不会触发「设置」弹窗。
  - 打开面板本身就会跑一次检查：先显示「正在检查 npm 上的版本…」（按钮变「检查中…」且不可再点），结束后给一句结论——`已是最新版本：x（通道 latest）` / `发现新版本 y…` / 失败原因（连不上 registry、或页面比插件旧要求按 ⌘R 重新载入），结论行末尾带检查时间。所以按钮点没点上、检查有没有成功，一眼能看出来。
  - 面板里的「检查更新」是同一套反馈（最短显示 450ms，避免本地毫秒级返回时看起来“没反应”）。
  - 升级动作会真的执行 `npm install -g @deepseek-ai/dsh@<版本>`，**升级完成后需要重启 DSH 才生效**（网页里重新载入不够，服务进程还是旧的；用应用菜单“重启 DSH 服务”，或在终端里 Ctrl-C 后重开）。

## 升级通道

默认策略：**只提醒 `latest`**。先分清 npm 的 dist-tag（`npm view @deepseek-ai/dsh dist-tags`）：

| tag | 含义 | 会提醒吗 |
|---|---|---|
| `latest` | 官方推荐的当前版本。`npm install -g @deepseek-ai/dsh` / `@latest` 拿到的就是它 | ✅ 会 |
| `next` | 下一个候选版本，通常比 `latest` 早发布 | ❌ 不会（默认隐藏） |
| `alpha` | 更早的开发预览 | ❌ 不会（默认隐藏） |

所以平时 `npm i -g @deepseek-ai/dsh` 能拿到的版本，就是版本号面板会提醒你去升的版本；`next`/`alpha` 不会打扰你。注意 DSH 目前只发布 `rc`/`alpha`，连 `latest` 本身也是 rc（例如 `latest = 0.1.5-rc.1`）——这里区分的是 **npm 的 tag**，不是版本号里有没有 `-rc`。

想尝鲜预发布（可选）：

- App 侧：`~/.dsh/desktop-shell/app.json` → `"showPrereleases": true`（配合 `"tag": "next"` 可跟随某个通道）；
- 插件侧：本目录 `cordis.patch.yml` 里 `desktop-shell` 行的 `config.showPrereleases: true`（改完 `patchReload: live` 会热加载，必要时重启 DSH）。

打开后，`⋯` 面板才会列出预发布版本（标注“（预发布）”）供你手动点击升级；关掉即恢复“只提醒 latest”。

## 默认权限（新建会话）

安装脚本会把**新建会话的默认权限**设为 `danger-full-access`（完全权限），两条腿同时落地：

1. **用户设置**：`~/.dsh/settings.yaml` 里的 `permission.defaultPreset: danger-full-access`。这就是 GUI「设置 → 通用 → 权限」那一行写的东西，DSH 在 `session/created` 时用它给新会话钉上 *sandbox + approval* 这对值。
2. **部署覆盖**：`~/.dsh/desktop-shell/app.json` 的 `"permissionMode": "danger-full-access"`。DSH.app 拉起子进程时设置官方环境变量 `DSH_PERMISSION_MODE`，它同时决定 `sandbox-policy.mode` 与 `approval.policy`（`danger-full-access` → approval `never`）。设为 `""` 即可关掉这条，只留 settings.yaml 的默认。

注意 DSH 的语义：**默认值只作用于此后新建的会话**，已有会话保留它创建时钉下的权限（所以改完设置后，旧会话仍显示原来的「工作区内修改」是正常的；点「新会话」就是「完全权限」）。

改回/切换：

```bash
bash macos/install.sh --permission workspace-write   # 改成工作区内修改（settings + app.json 同步）
bash macos/install.sh --no-permission                # 只装 App/插件，不动权限设置
python3 macos/set-permission-default.py --clear      # 移除设置项，回到 DSH 组合默认值
bash macos/uninstall.sh --restore-permission         # 卸载时一并还原
```

> 完全权限 = 不再有工作区文件边界、也不再弹审批。这是你明确要求的启动默认值，介意安全的话用上面两条命令随时改回。

## 启动速度（第一次约 3 秒，之后秒开）

冷启动那几秒**不是 App 的锅**，是 DSH 自己在启动时组装浏览器插件包：CPU profile 显示 ~3s 里有 **1.7s 花在 `dsh-client-modules` 的 `buildCombo` / 哈希**（读 ~50 个 client bundle 并拼成内容寻址的 combo 包），剩下是 ESM 装载与 buffer 处理。登录 shell、`NODE_COMPILE_CACHE` 都几乎没有影响（实测 2.96s vs 2.96s）。这部分要动就得改 DSH 内部，违背本项目「不碰 DSH 内部」的原则，所以不改。

采取的方案是**让服务常驻、App 附着**（不碰 DSH，反而更耐升级）：

| 场景 | 实测 |
|---|---|
| 冷启动（现起服务） | ~3.7s（含 `open -a` 与 App 启动） |
| 退出 App 后再打开（附着后台服务） | **~0.35s** |

- 退出 App 时，**本 App 启动的**后台服务会保留（默认 30 分钟，之后由一个 detached watchdog 回收）。watchdog 靠 `~/.dsh/desktop-shell/app.pid` 这个**租约文件**判断 App 是否还在运行（不用进程名：macOS 的 `comm` 会把 `/Applications/DSH.app/...` 截断成 `/Applications/DS`，按名字判断会误杀），所以窗口期内重开 App 就会自动取消回收。
- 想改行为：`app.json` 的 `lingerMinutes` —— `0` = 退出即停（回到原来的一次性进程模型）、`30` = 保留 30 分钟（默认）、`-1` = 一直保留到手动停。
- 想立刻释放：菜单 `文件 → 停止后台 DSH 服务并退出`（实测：App 与服务都干净退出）。
- 代价：保留期间有一个 `node dsh web` 常驻，实测 **~286MB RSS**；不想要就设 `lingerMinutes: 0`。
- **安全边界**：如果当前服务是你在终端里启动的（`endpoint.json` 的 `desktopShell: false`），App 只会附着、**绝不会在退出时杀掉它**；同理升级完成后 App 也只停自己启动的服务。

## 卸载

```bash
bash macos/uninstall.sh            # 反注册 bundle + 删除 App，保留配置、日志与源码
bash macos/uninstall.sh --keep-app # 只反注册插件（网页恢复原样）
bash macos/uninstall.sh --purge    # 连 ~/.dsh/desktop-shell 一起删
```

反注册走官方的 `dsh plugin --profile web remove dsh-plugin-desktop-shell`；**插件源码目录本身不会被删**（它就是长期位置），不需要了手动删掉即可。

## 文件一览

```
~/.dsh/profiles/web/plugins/dsh-plugin-desktop-shell/
├── package.json                  # name + dsh.bundle.patch → cordis.patch.yml
├── cordis.patch.yml              # bundle 层：insert 主机插件（name 相对本文件锚定）
├── lib/index.js                  # DSH 插件（零依赖，含注入的网页 UI）
├── macos/main.swift              # 整个 App（WKWebView + 进程管理 + 更新检查）
├── macos/Info.plist              # bundle 元数据
├── macos/build-app.sh            # swiftc 构建 + 生成图标 + ad-hoc 签名
├── macos/make-icon.swift         # 用 AppKit 画 App 图标并产出 .icns
├── macos/install.sh              # 构建/安装 App + 官方注册插件 + 自检
├── macos/uninstall.sh            # 反注册（--keep-app / --purge / --restore-permission）
├── macos/set-permission-default.py  # 幂等写/清 settings.yaml 的 permission.defaultPreset
└── docs/REPAIR.md                # 给“下一个 agent”的接口契约与修复手册
```

## 为什么升级 DSH 后大概率不用改（兼容性设计）

1. **插件零依赖**：只用 Node 内置模块和 DSH 的公开服务 `webServer` / `connection`，**不 import 任何 `@deepseek-ai/*` 包**——所以不存在版本对齐、重复实例、peer 冲突问题。
2. **界面用官方 escape hatch 注入**：`ctx.webServer.tapIndex()`（DSH 明确定义的“结构化注入行表达不了的 markup 就用它”的入口），往 `index.html` 追加一段自包含的原生 JS/CSS。**不依赖客户端插件契约**（client bundle 的 `__ModuleLoader__` 工厂格式、`dsh.client` 清单、slot API 都可能有变动）。
3. **App 只依赖一件事**：`dsh web --no-open` 会打印 `dsh web: http://127.0.0.1:<port>/?token=…`。URL 提取用的是宽松正则（优先带 `token=` 的回环地址）。参数被未来版本拒绝时，App 会自动去掉额外参数重试一次；启动失败时把原始输出显示在窗口里而不是白屏。
4. **配置全外置**：端口、附加参数、npm 通道、registry、dsh 可执行文件位置、启动权限覆盖都在 `~/.dsh/desktop-shell/app.json`，改配置不需要重新编译；插件侧配置在本目录 `cordis.patch.yml` 的 `desktop-shell` 行里，改完热加载；默认权限的另一半在 `settings.yaml`，用脚本幂等读写。
5. **两半解耦**：插件挂了 App 照常能开、能升级；App 挂了浏览器里的 DSH 照常能用、版本号面板照常能升级。卸载其中一半不影响另一半。

## 故障排查

| 现象 | 怎么办 |
|---|---|
| App 窗口显示“启动失败/超时” | 看 `~/.dsh/desktop-shell/dsh-shell.log`；确认 `dsh` 在登录 shell 的 PATH 里（`/bin/zsh -lc 'which dsh'`）；必要时在 `app.json` 写死 `"dshBin": "/opt/homebrew/bin/dsh"` |
| 「设置」按钮里没有版本号 | 先看 `~/.dsh/profiles/web/package.json` 的 `dsh.profile.bundles` 有没有 `dsh-plugin-desktop-shell`；没有就 `bash macos/install.sh --no-app`。再重启 DSH。命令行自查：`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port>/desktop-shell/status` 返回 **401** 说明插件在（404 说明没加载） |
| 点升级报权限错误 | npm 全局目录不可写：`npm prefix -g` 看位置，或用 `sudo npm install -g @deepseek-ai/dsh@<版本>` 手动升级 |
| 升级完成但界面还是旧版本 | 服务进程还是旧的：应用菜单“文件 → 重启 DSH 服务”，或终端里重启 `dsh web` |
| App 附着到了终端的 DSH | 这是设计行为（`endpoint.json` 里有活的 pid 就附着）。想强制新起一个：删掉 `~/.dsh/desktop-shell/endpoint.json`，或把 `app.json` 的 `attachToRunning` 设为 `false` |
| 新会话权限不是「完全权限」 | 查三处：`~/.dsh/settings.yaml` 有没有 `permission: {defaultPreset: danger-full-access}`；子进程环境有没有 `DSH_PERMISSION_MODE`（`ps eww -p <pid>`）；点版本号面板里的「新会话默认权限」。三者一致但仍不对，说明 DSH 改了 `pinInitialPermission` 的语义 |
| 第一次打开要等约 3 秒 | DSH 启动时组装浏览器插件包的固有成本（见上节）。退出后别关后台服务即可秒开；`lingerMinutes` 控制保留时长 |
| 退出 App 后还有 `dsh web` 进程 | 这是 `lingerMinutes`（默认 30 分钟）的常驻后台服务，为的是下次秒开。`文件 → 停止后台 DSH 服务并退出` 可立刻结束 |
| 关掉窗口后再点 Dock 图标（或 `open -a DSH`）App 直接消失 | 已知崩溃：`NSWindow.isReleasedWhenClosed` 默认 `true`，关窗后强引用变悬垂指针，reopen 时在 `objc_msgSend` 里 `EXC_BAD_ACCESS`。已修：`buildWindow()` 置 `false`，reopen 时重建窗口并激活。用 `bash macos/install.sh --no-plugin --no-permission` 重装 App 即可 |
| 改了默认权限，旧会话还是「工作区内修改」 | 正常：DSH 的默认只作用于**新建**会话，已有会话保留创建时钉下的权限。点「新会话」即可 |
| 截图发不出去（`could not create image from display`），系统设置里 DSH 已勾选 | 屏幕录制授权绑代码身份，且只对**授权之后启动**的进程生效。步骤：`tccutil reset ScreenCapture local.dsh.shell` → 打开 DSH（应用菜单「DSH → 屏幕录制权限…」会直接弹系统询问）→ 按提示勾选 → 点对话框里的「立即重新打开」。之后重建 app 不再需要重新授权（前提是 app 用证书签名，见 `docs/REPAIR.md`）。诊断看日志里的 `screen recording:` 行 |

修复/扩展请先读 `docs/REPAIR.md`。
