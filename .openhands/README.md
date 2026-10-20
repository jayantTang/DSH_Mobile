# 本机 OpenHands 配置（无 Docker）

`settings.json` 是本仓库的**唯一事实源**，由 `scripts/openhands-local.sh`、`.githooks/pre-commit`
与 `scripts/local_ai_review.py` 读取；OpenHands 上游不认这个文件名，所以字段与上游的映射如下：

| settings.json | 实际生效方式 |
|---|---|
| `runtime: "process"` | 启动器导出 `RUNTIME=process`，选中 ProcessSandboxService |
| `max_iterations: 5` | 同步写入仓库根 `config.toml` 的 `[core] max_iterations`，OpenHands 启动即读 |
| `agent_mode: "single_developer"` | 启动器拒绝多 Agent 参数，并把该值写入 `OPENHANDS_AGENT_MODE` |
| `sandbox.docker: false` | 启动器检测到 `RUNTIME=docker` 等显式容器配置时直接退出 |
| `guard.*` | 由本地提交防线与审查脚本读取，不进入 OpenHands 运行时 |

上游字段口径见 [Process Sandbox](https://docs.openhands.dev/openhands/usage/sandboxes/process)
与 `config.template.toml` 的 `[core] max_iterations`。

## 使用

```bash
scripts/openhands-local.sh            # 进入本地进程模式；未安装 CLI 时会给出安装提示
scripts/local_ai_review.py --staged   # 单独跑一次 Diff 审查
scripts/targeted_tests.py --staged    # 单独跑一次靶向测试
```

本机不安装、不使用 Docker；上述脚本与 OpenHands CLI 是否存在无关。
