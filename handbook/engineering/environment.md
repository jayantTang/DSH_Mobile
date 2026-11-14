# 环境与运行

## DSH 重启与热更

修改 skill 后必须重启 DSH；连接器与插件源码走热更，无需重启。

连接器代码运行在 DSH 进程内。当前可以自行重启，不必要求用户到电脑前操作：`npm run restart -- --resume "继续…"` 会终止旧后端、启动新后端并唤醒当前会话，过程记录在 `~/.dsh/restart/`（详见 skill `dsh-restart`）。确认后端进程：

```bash
ps -eo pid,lstart,command | grep 'bin/dsh web' | grep -v grep
```

插件源码已支持热更，无需重启。`scripts/dev/plugin-hmr.mjs`（`npm run plugin:hmr on|off|status`；`install-all.sh` 安装插件时已自动开启）把基础组合中 `hmr` 条目的 `root` 指向 `<repo>/plugins`：修改 `plugins/*/lib/*.js` 保存后即生效，宿主 pid 不变。`lib/client.js`（客户端部分）依赖 DSH 自带的 `dsh-client-hmr`（`/plugins/events` 的 `rebuilt` 帧），机制与帧均已确认，但桌面版界面「不刷新即换新」尚未验证（003 FR-010 记录）。官方 README 中的 `root: ["."]` 对本仓库无效，因为档案中的 `node_modules/dsh-plugin-*` 只是指向仓库的符号链接。

新增插件不需要重启（实测：在命令行 web 宿主上执行 `dsh plugin --profile web add …`，安装后立即生效，宿主 pid 不变；macOS 与 Linux 各测一次，见 `handbook/history/验收/006-三级验证渠道.md`）。替换同名包（升级）仍需重启；未启用 hmr 时，卸载需要停止进程。这两条是官方包管理器的规则。实测记录见 `handbook/history/验收/003-插件热插拔.md`。

插件改动一律按「不需要重启 DSH」设计。改动优先落在 `plugins/*/lib/*.js`（服务端部分，plugin-hmr 保存即生效）。尽量避免只有重启才生效的三种形态：替换同名包（升级）、卸载后重装、把逻辑放进 skill。如果需求必须修改客户端部分（`lib/client.js`）或包结构，方案中必须写明「不重启如何生效」的路径与验证方法（例如宿主重建 bundle 后由 `rebuilt` 帧重载，以及需要用户刷新窗口还是重开面板），并将其列为待验项；不得用「重启一下即可」作为默认结论。

更新操作：修改完成后先确认热更已开启（`npm run plugin:hmr status` 显示 `web: on` / `desktop: on`），再按触发路径复验（重开面板、刷新页面或重新发起一次请求）。插件源码改动不得通过重装或重启生效；只有命中上述三种例外时才重装或重启，并在汇报中说明原因。

## 重启 App 与后端

重启 App 不等于重启后端。常见情况是 App 进程已更换，旧的 `node .../bin/dsh web` 仍在运行，新 App 复用了它。确认后端 PID 也已更换：

```bash
ps -eo pid,ppid,lstart,command | grep -iE 'DSH\.app|bin/dsh' | grep -v grep
```

旧后端仍在运行时（`PPID=1`），用 `kill <旧后端 PID>` 终止，再重开 DSH。

不得 `kill -9` 桌面版后用 `open -a` 重开。agent 的 shell 携带宿主注入的 `ELECTRON_RUN_AS_NODE=1`，`open` 会把它传给被启动的应用，应用被当作普通 Node 启动并静默退出，退出码 0：没有窗口、没有崩溃报告、没有诊断文件。2026-11-01 的事故即由此产生。重开一律使用 `npm run restart`（`scripts/dev/dsh-restart-worker.mjs`：清理环境、清理陈旧单实例文件、直接启动二进制）；只重开应用、不动后端时，使用同一文件导出的 `launchAppDirect()`。

## 运行环境

- 本机没有也不启用 Docker，任何方案不得依赖容器、镜像或远程 CI 才能完成本地验证。
- 本地提交防线：`.githooks/pre-commit` → `scripts/targeted_tests.py` → `scripts/local_ai_review.py`。
- 模型审查走本机 OpenAI 兼容端点（默认 `127.0.0.1:8799/v1`），超时 5 秒即跳过，不阻塞提交。

## 本机数据

- 仿真器验证产生的临时会话，用 `node scripts/dev/dsh-probe.mjs cleanup <id>` 删除。
- 运行单测前把 `DSH_HOME` 指向临时目录。曾因未隔离，把真实连接器凭据覆盖为 `agt_test` / `as_test`，导致手机重连失败。
- 不得删除或改写 `~/.dsh/` 下的真实会话。
- 连接器凭据从 `~/.dsh/mobile-link/agent.json` 读取，不得硬编码。
- 本机凭据清单见 `AGENTS.local.md`（本机覆盖，不入库）。
