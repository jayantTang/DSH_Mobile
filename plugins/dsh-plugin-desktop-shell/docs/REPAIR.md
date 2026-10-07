# 修复契约（给下一个 agent）

目标：DSH 升级后如果这个项目坏了，**只改这一个仓库**就能修好，不需要读我的心路历程。
先读本页的「稳定接口」，再查「故障模式 → 修哪里」。

## 1. 稳定接口（改动这些等于破坏契约）

### 1.1 文件

| 路径 | 谁写 | 谁读 | 内容 |
|---|---|---|---|
| `~/.dsh/desktop-shell/app.json` | `macos/install.sh`（首次），用户 | DSH.app | App 配置，见 1.2 |
| `~/.dsh/desktop-shell/app.pid` | DSH.app（启动时写、退出时删） | App 自己 spawn 的 linger watchdog | App 租约：`pid=<App pid>\nstarted=<ISO>`。watchdog 只看它 + `kill -0`，**不要改回按进程名判断** |
| `~/.dsh/desktop-shell/endpoint.json` | 插件（DSH 启动后、树稳定时） | DSH.app | `{ url, port, pid, version, desktopShell, updatedAt }`；`desktopShell` = 该服务是否由 App 启动（false/缺失 = 用户在终端启动的，App 绝不可杀）；`url` 是带 `?token=` 的认证地址，权限 0600；进程退出时由插件删除（只有 `pid === process.pid` 才删） |
| `~/.dsh/desktop-shell/dsh-shell.log` | DSH.app | 人 | 启动/发现 URL/退出/附着 的日志 |
| `~/.dsh/profiles/web/package.json` | `dsh plugin --profile web add/remove`（`macos/install.sh` 调用它） | DSH Loader | 官方注册点：`dependencies["dsh-plugin-desktop-shell"] = "link:plugins/dsh-plugin-desktop-shell"`，且 `dsh.profile.bundles` 含 `dsh-plugin-desktop-shell`。用 `dsh plugin` 维护，保证 pnpm 的状态一致 |
| `~/.dsh/profiles/web/node_modules/dsh-plugin-desktop-shell` | pnpm（`link:` 符号链接） | DSH Loader | 指向本包目录。源码永远在本目录，链接只是注册手段 |
| `<plugin>/package.json` + `<plugin>/cordis.patch.yml` | 人 / agent | DSH Loader | bundle 契约：`dsh.bundle.patch → ./cordis.patch.yml`；patch 里 `insert: [{ id: desktop-shell, name: './lib/index.js' }]`（相对本文件锚定，DSH 会改成 file URL） |
| `~/.dsh/profiles/web/cordis.patch.yml` | 用户自己的 patch 层（安装脚本只在迁移旧版时清理） | DSH Loader | 必须保持**顶层 YAML 数组**。旧版的 `# >>> dsh-macos-shell` managed block 已被移除；只剩注释时要补一个 `[]`，否则 DSH 起不来（`must be a top-level YAML array`） |

注册等价于（幂等，可随时重放）：
```bash
cd ~/.dsh/profiles/web && dsh plugin --profile web add link:plugins/dsh-plugin-desktop-shell
```
以后插件侧改动直接改本目录；`patchReload: live` 会热加载 patch 文本，改了已 `import` 的 JS 需要重启 DSH。

### 1.2 `app.json` 字段（全部可选，缺省值见 `macos/main.swift` 的 `ShellConfig`）

`appTitle`, `dshBin`, `extraArgs`（默认 `["--port","0"]`）, `initialURL`, `attachToRunning`,
`checkUpdates`, `tag`（跟随的 dist-tag，默认 `"latest"`）, `showPrereleases`（默认 `false`）,
`permissionMode`（默认 `"danger-full-access"`，作为环境变量 `DSH_PERMISSION_MODE` 传给子进程；`""` = 不覆盖）,
`lingerMinutes`（默认 `30`：退出后保留后台服务多少分钟；`0` = 退出即停，`-1` = 一直保留）,
`npmBin`, `registry`, `startupTimeoutSeconds`。旧的 `channel` 仍作为 `tag` 的别名读取。

**提醒策略（默认）**：只有跟随 tag（默认 `latest`）比本地新时才提示；`showPrereleases: false` 时
`next`/`alpha` 等预发布既不提醒也不出现在 UI。App 与插件必须保持同一策略。

### 1.3 插件路由（都由 DSH 自己的 `connection.requestRejection` 保护：Host/Origin = 403，未认证 = 401）

| 方法 | 路径 | 额外要求 | 返回 |
|---|---|---|---|
| GET | `/desktop-shell/status` | 请求头 `x-dsh-desktop-token` | `{ ok, installed, installedPath, latest, tag, channel, showPrereleases, distTags, newerTags, updateAvailable, registry, wrapper, port, pid }`；`defaultPermission` 是 host 侧 `permissionPresets.defaultPreset` 的只读投影；`newerTags` 默认只含跟随 tag（`latest`），`distTags` 默认只回 `{<tag>: <version>}`，预发布不交给前端 |
| POST | `/desktop-shell/upgrade` | 同上 + body `{ "version": "0.1.5-rc.2" }` | `{ ok, version, code, output, restartRequired }`；版本号用 `^[0-9A-Za-z][0-9A-Za-z.+-]*$` 校验后才拼进 shell 命令 |
| POST | `/desktop-shell/open-app` | 同上 | 执行 `open -a <appName>` |
| POST | `/desktop-shell/open-config` | 同上 | 执行 `open <~/.dsh/desktop-shell>` |

`x-dsh-desktop-token` 是**每个进程随机生成**的，只出现在注入到 `index.html` 的 `<script id="dsh-desktop-shell-banner">` 里（`var TOKEN = "…"`）。它是 cookie 之外的第二道锁，注入脚本每次载入都会拿到新的。

### 1.4 环境变量

- `DSH_DESKTOP_SHELL=1`：App 拉起子进程时设置，插件据此在 status 里报 `wrapper: true`（网页里就不显示“在桌面应用中打开”）。
- `DSH_NO_DESKTOP_ENDPOINT=1`：让插件**不写** `endpoint.json`。`install.sh` 的自检实例用它，避免覆盖正在运行实例的交接文件。

### 1.5 App 对 DSH 的唯一依赖

1. `dsh web --no-open [extraArgs]` 会启动服务并在 **stdout** 打印 `dsh web: http://127.0.0.1:<port>/?token=<t>`；
2. 直接把 WKWebView 指向这个 URL 就能完成 `?token=` → 303 + `Set-Cookie` → `/` 的认证跳转；
3. 有活着的 `endpoint.json`（pid 存活）时改为附着，不新起进程。

### 1.5 默认权限契约

- **用户默认**：`~/.dsh/settings.yaml` → `permission.defaultPreset: read-only | workspace-write | danger-full-access`。
  由 `macos/set-permission-default.py` 幂等读写（只动 `permission:` 段，不重排其它内容）。这就是 GUI「设置 → 通用 → 权限」那一行。
- **部署覆盖**：子进程环境 `DSH_PERMISSION_MODE`（`macos/main.swift` 从 `app.json` 的 `permissionMode` 注入）。
  `dsh-base` 的行读它：`sandbox-policy.mode = process.env.DSH_PERMISSION_MODE ?? 'workspace-write'`，
  `approval.policy = env === 'danger-full-access' ? 'never' : 'ask'`。
- **生效时机**：`dsh-permission-presets` 的 `pinInitialPermission()` 在 `session/created` 时把默认预设钉进**新会话**；
  已有会话保留自己的 knobs。所以「改了默认但旧会话没变」是设计行为，不是 bug。
- 安装脚本会让上面两处保持一致（`--permission <preset>` 同时改两处，`--no-permission` 两处都不动）。

### 1.6 启动速度与常驻服务契约

- 冷启动 ~3s 是 **DSH 自身** 的开销（profile 显示 ~1.7s 在 `dsh-client-modules` 组装 client bundle combo），不要试图在 App 侧“优化”它，也不要改 DSH 内部。
- 加速手段是 **附着**：`DSHServer.start()` 先读 `endpoint.json`，pid 活着就直接加载 `url`（实测 ~0.35s），否则才 spawn。**不要破坏这个先后顺序**。
- 退出策略（`applicationWillTerminate`）：`lingerMinutes == 0` → `stopAll()`；否则若 `ownsServer` → 保留进程并 `scheduleLingerReap(pid:minutes:)`。
  watchdog 命令（detached `/bin/sh -c`）：
  `sleep N; if [ -r app.pid ]; then APID=$(sed -n 's/^pid=//p' app.pid | head -n1); if [ -n "$APID" ] && kill -0 "$APID"; then exit 0; fi; fi; if kill -0 <server-pid>; then kill <server-pid>; fi`
  —— **租约文件 + `kill -0` 就是“重开即取消回收”的全部机制**。
  ⚠️ 不要改成 `pgrep -x DSH`：macOS 上 App 的 `comm` 是截断到 15 字符的可执行路径（实测 `ps -o comm=` 得到 `/Applications/DS`），按名字永远匹配不到，结果就是**用户正在用时服务被回收**。租约 pid 失效（App 崩溃残留）也必须允许回收，所以判断是 `kill -0 $APID` 而不是文件是否存在。
- 归属规则：`ownsServer = spawnedPid != nil || (attached && attachedOwned)`，`attachedOwned` 来自 `endpoint.desktopShell`。
  终端启动的服务 `owned=false` → 退出时只记一行 `leaving non-owned server alone`，**不杀**。
- 升级成功后会 `stopAll()` 只停自己拥有的服务，否则新版本不会生效（旧进程仍跑旧代码）。

## 2. 故障模式 → 修哪里

| 症状 | 原因 | 修复位置 |
|---|---|---|
| App 显示“等待 DSH 启动超时”，日志里没有 URL | 启动行格式变了 / flag 变了 | `macos/main.swift` 的 `DSHServer.extractURL`（正则）或 `ShellConfig.extraArgs` 默认值。self-healing 已经会在 flag 报错时去掉 extraArgs 重试一次 |
| 窗口白屏/提示无法连接 | token→cookie 流程变了 | 先用 `curl -c jar "http://127.0.0.1:<port>/?token=<t>"` 看是否 303 + Set-Cookie；若是，检查 App 是否用了非默认 data store（必须 `WKWebsiteDataStore.default()` 才能存 cookie） |
| 「设置」按钮里没有版本号，但 `/desktop-shell/status` 返回 401 | 注入没生效或找不到锚点 | `lib/index.js` 的 `tapIndex` 段与 `findSettingsButton()` / `findSettingsLabel()` / `positionBadge()`。锚点约定：DSH 侧边栏设置触发是 `<button aria-label="设置\|Settings">`，内含文本为 `设置`/`Settings` 的 `span`；版本号插在这个 span 之后（`insertAdjacentElement('afterend', badge)`）。找不到锚点时 chip 隐藏，不影响其它功能。若 DSH 去掉 `tapIndex`，插件会 catch 并只打 warning（不拖垮启动），退化成“只能用 App 菜单升级” |
| `/desktop-shell/status` 返回 404 | 插件没加载 | 查 `~/.dsh/profiles/web/package.json` 的 `dsh.profile.bundles` 有没有 `dsh-plugin-desktop-shell`；没有就 `bash macos/install.sh --no-app`；确认 `node --check lib/index.js` 通过；确认 `~/.dsh/profiles/web/cordis.patch.yml` 仍是合法顶层数组 |
| 所有路由都 403 | `connection.requestRejection` 语义/服务名变了 | `lib/index.js` 的 `rejected()`；如果新版本提供了等价的信任服务，替换 `connectionOf()` 的取值。**不要**为了让它能跑就删掉这道检查 |
| 插件加载失败导致 DSH 起不来 | 插件顶层抛异常 | `apply()` 内部已 try/catch 各能力，但 import 期（顶层）出错仍会失败。保持顶层只做 import/常量定义；`node --check` + README 里的自检命令先验证 |
| 路由前缀 `/desktop-shell` 与别的插件撞了 | `webServer.register` 重复路径会 throw | 换前缀（同时改注入脚本里的 `BASE`） |
| 升级命令失败（EACCES / 不是 npm 布局） | DSH 换成 pnpm/homebrew/pip 安装 | `app.json` 的 `npmBin`；必要时给插件加 `upgradeCommand` 配置（当前实现固定 `npm install -g @deepseek-ai/dsh@<ver>`，在 `runUpgrade` 附近） |
| 版本号识别错（曾把插件自己的 0.1.0 当 DSH 版本） | 向上遍历 package.json 命中无关包 | `lib/index.js` 的 `findInstalledVersion`：必须校验 `name === '@deepseek-ai/dsh'`；优先用 `createRequire(profileDir/package.json).resolve('@deepseek-ai/dsh/package.json')` |
| 点版本号面板里的「检查更新」像“按不动” | 检查结果没有可见反馈：本地 `GET /status` 毫秒级返回，面板文字前后完全一样；页面比插件旧时每次调用都 403，而旧代码把失败静默吞掉 | `lib/index.js` 的 `refresh()` / `settle()` / `renderPanel()`：交互检查先画「正在检查…」+ 禁用按钮，最少显示 `MIN_CHECK_MS`（450ms），结束必给结论（已是最新版本 x / 发现新版本 y / 为什么失败），403 直接提示「按 ⌘R 重新载入」。判断“点没点上”看结论行末尾的时间戳 |
| 新会话权限不对 | 默认权限的两处不一致或未被读取 | 查 `settings.yaml` 的 `permission.defaultPreset`、子进程 `DSH_PERMISSION_MODE`、`/desktop-shell/status` 的 `defaultPermission`；若三者都对仍无效，是 DSH 改了 `pinInitialPermission` 的语义，改 `macos/set-permission-default.py` 与 `macos/main.swift` 的注入 |
| 退出 App 后后台服务没保留 | 看日志有没有 `keeping dsh pid … alive`；若显示 `leaving non-owned server alone`，说明端点里 `desktopShell` 不是 true（服务不是 App 起的），属预期 |
| 关窗后再点 Dock / `open -a DSH`，App 崩溃（`EXC_BAD_ACCESS`，栈顶 `objc_msgSend` ← `applicationShouldHandleReopen`） | `NSWindow.isReleasedWhenClosed` 对程序化创建的窗口默认是 `true`；关窗时 AppKit 释放了窗口，ARC 下的强引用变成悬垂指针，reopen 时向已释放对象发消息 | `macos/main.swift` 的 `buildWindow()`：`window.isReleasedWhenClosed = false`；`applicationShouldHandleReopen` 里 `window == nil` 时重建窗口并 `NSApp.activate`。修完必须重装：`bash macos/install.sh --no-plugin --no-permission` |
| 中文输入法（拼音/五笔）组字时按退格：删掉带下划线的最后一个字符，会把前面**已上屏**的那个汉字一起删掉（浏览器里不复现，只有 App 里有） | App 把 `webView.customUserAgent` 赋成了 `DSHShell/1.0`。`customUserAgent` 是**整体替换**默认 UA（`webView.customUserAgent` 初值为 nil，拿不到默认值），于是 `navigator.userAgent` 里没有 `AppleWebKit/…`。GUI 的编辑器（Lexical）靠 `/AppleWebKit\/[\d.]+/ && Mac && !Chrome` 判断「是不是 WebKit」，判定为 false 后走了非 WebKit 的组字分支（`compositionend` 立即结算而不是延迟到下一次按键），组字结束的删除就多删一个字符 | `macos/main.swift` 的 `buildWindow()`：删掉 `webView.customUserAgent = …`，改用 `webConfig.applicationNameForUserAgent = "DSHShell/1.0"`（追加到默认 UA 后面）。自检：在同配置的 WKWebView 里 `navigator.userAgent` 必须仍含 `AppleWebKit/605.1.15`，`platform` 是 `MacIntel`；改完 `bash macos/build-app.sh && rm -rf /Applications/DSH.app && cp -R macos/build/DSH.app /Applications/`，**重启 App** 才生效 |
| 终端里的 dsh 被 App 退出杀掉了（回归） | `stopSpawned` / `stopAttachedIfOwned` 的归属判断被改坏了：只有 `ownsServer == true` 才能杀；`desktopShell=false` 必须放行 |
| 后台服务在用户使用中被 watchdog 杀掉（回归） | watchdog 的租约检查被删/写错，或有人把它改回按进程名判断（macOS `comm` 截断，必然误杀）。正确判据：`app.pid` 里的 pid 仍能被 `kill -0` 找到就不回收 |
| 窗口期内重开 App 仍被回收 | App 启动时没写 `app.pid`（`writeLease()` 被绕过），或退出时 `removeLeaseIfOurs()` 误删了别人的租约 |
| 退出后 `endpoint.json` 残留 | 异步清理被进程退出打断 | 插件销毁回调必须用**同步** fs（当前就是 `readFileSync` / `rmSync`） |
| 截图一直失败（`could not create image from display`），系统设置里 DSH 明明已勾选 | Screen Recording 授权是给**某个代码身份**的。ad-hoc 签名没有稳定身份，TCC 只能按 cdhash 记 —— 重建一次 app 授权就作废；另外 macOS 只把新授权交给**之后启动**的进程，勾完不重启也不生效 | 签名改为证书（`macos/build-app.sh` 已这么做，身份取 `DSH_CODESIGN_IDENTITY`，否则第一个 codesigning 身份）。修复顺序：`tccutil reset ScreenCapture local.dsh.shell` → 打开 app 勾选 → 退出重开。日志里看 `screen recording:` 行：`NOT granted` = 没勾；`granted (probe ok=false)` = 勾了但当前进程没拿到，重开即可 |
| 每次重建 app 后截图又要重新授权 | 签名退回成了 ad-hoc（`codesign --sign -`） | `macos/build-app.sh` 的签名段：找不到身份时会打印警告并退回 ad-hoc，别把这行警告当噪声。检查：`codesign -dvvv /Applications/DSH.app` 应显示 `Authority=Apple Development: …`，且 `sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select length(csreq) from access where service='kTCCServiceScreenCapture' and client='local.dsh.shell'"` 是 160（证书型）而不是 40（cdhash 型） |

## 3. 改动流程（最快路径）

**只改插件**（无需构建；patch 热加载，改 JS 后重启 DSH 生效）：
```bash
node --check lib/index.js
bash macos/install.sh --no-app      # 幂等重放官方注册 + 自检
# 完全重启 DSH（patchReload 只对 patch 文本热更新，已 import 的模块 URL 有缓存）
```

**只改 App**：
```bash
bash macos/build-app.sh
rm -rf /Applications/DSH.app && cp -R macos/build/DSH.app /Applications/
```

**诊断三连**：
```bash
PORT=$(python3 -c "import json;print(json.load(open('$HOME/.dsh/desktop-shell/endpoint.json'))['port'])")
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$PORT/desktop-shell/status"  # 401 = 插件在；404 = 没加载
cat ~/.dsh/desktop-shell/endpoint.json 2>/dev/null                                    # App 是否会附着
tail -20 ~/.dsh/desktop-shell/dsh-shell.log                                           # App 侧发生了什么
grep -A2 '^permission:' ~/.dsh/settings.yaml                                          # 默认权限设置项
ps eww -p "$(pgrep -f 'dsh web --no-open' | head -1)" | tr ' ' '\n' | grep DSH_PERMISSION_MODE
python3 -c "import json;d=json.load(open('$HOME/.dsh/desktop-shell/endpoint.json'));print(d['pid'],d.get('desktopShell'))"  # 附着对象归属
grep -E "attached to running|keeping dsh|scheduled linger|leaving non-owned" ~/.dsh/desktop-shell/dsh-shell.log | tail -5
```

## 4. 设计红线（修的时候别破坏）

1. **插件不 import 任何 `@deepseek-ai/*` 包**。一旦引入，就会绑定 cordis/schemastery 的实例与版本；现在它只用 node 内置模块，所以跨版本最稳。
2. **提醒策略是 latest-only**：默认只提醒 `latest`，且 host 侧不把预发布 channel 交给前端（`showPrereleases: false` 时 `distTags` / `newerTags` 都已过滤）。改策略只改 `buildStatus()` 这一个纯函数，并同步 `macos/main.swift` 的对应逻辑，别在 UI 里另写一套判断。
3. **不用客户端插件（client bundle）机制**。那套 `__ModuleLoader__` 工厂格式、`dsh.client` 清单、slot API 都是内部契约；`tapIndex` 注入原生 JS 更耐升级。
4. **不写死端口**。App 用 `--port 0`，从 stdout 拿真实端口；插件用 `ctx.webServer.port`。
5. **升级动作要用户点击**，不要静默自动升级；命令里拼接的版本号必须先做字符白名单校验。
6. **失败要可见**：App 出错时把子进程输出画进窗口（`showPlaceholder`），插件出错只 warning 不拖垮 DSH 启动。
7. **两半保持独立**：不要为了省事让 App 依赖插件，或让插件依赖 App 的产物。
8. **常驻服务只归 App 自己管**：`desktopShell` 不是 true 的实例（用户在终端启动的）只能附着、不能杀；watchdog 回收前必须先用 `app.pid` 租约确认 App 没在运行（**不要用进程名**）。
9. **默认权限两处必须同步**：`settings.yaml` 的设置项与 `app.json` → `DSH_PERMISSION_MODE` 由 `install.sh` 一起改；只改一处会让「组合默认」和「用户默认」打架，排查时以插件 status 的 `defaultPermission` 为准。
