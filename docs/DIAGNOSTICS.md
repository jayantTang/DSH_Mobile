# 链路诊断

面向排障的采集与判读说明。一条命令产出一个诊断包，包内是三侧（手机 App、公网中转、本机连接器）
记录的同一条时间线，用来回答四类问题：连不上停在哪一跳、连上耗时长卡在哪一段、加载慢在哪一段、
同步慢是取数慢还是传输慢。

## 一、采一次

```bash
npm run diag:collect                       # 默认取最近 30 分钟
npm run diag:collect -- --since 6h         # 窗口可调（30m / 6h / 2d 或 ISO 时刻）
npm run diag:collect -- --device dev_xxx   # 只采某台设备（自验时用于调试设备）
npm run diag:collect -- --out /tmp/diag    # 指定输出目录
npm run diag:collect -- --no-relay         # 跳过中转侧（无 ssh 时用，包内会标为主动跳过）
```

产物是一个目录（默认在 `~/dsh-diagnostics/diagnostics-<时间戳>/`）：

| 文件 | 内容 |
|---|---|
| `README.md` | 本次采了什么、窗口、每次接入的阶段表、怎么判读 |
| `timeline.jsonl` | 三侧合并到同一个时钟后按时间排序 |
| `attaches.jsonl` | 每次接入一行：六个阶段耗时 + 连接器侧的三个数 + 缺失阶段 |
| `sources/connector.jsonl`、`sources/relay.log`、`sources/status.json` | 原始切片（可追溯） |
| `clock.json` | 各来源与本机的时钟偏移 |
| `coverage.json` | 每来源的条数、窗口、被滚动丢弃的标注、并进时间线的来源 |
| `missing.json` | 缺了哪些来源与下一步 |

退出码：`0` 无缺失；`1` 出包但缺来源；`2` 未出包（脱敏或结构检查未通过、参数错、输出目录已存在）。

## 二、判读四类问题

**1. 连不上：停在哪一跳。** 在 `timeline.jsonl` 上按顺序找三件事——`app.dial(phase=start)`
（手机开始拨号）、`relay.device-attach`（中转收到接入）、`device.attach`（连接器收到接入）。

| 现象 | 含义 |
|---|---|
| 三件都没有 | 手机根本没拨号（App 被系统挂起，或用户未操作）。`app.scene` 能看出当时是否在后台 |
| 有 `dial(start)`，没有 `dial(transport-up)` | 拨号卡在传输建立之前（网络/DNS/TLS/WS 握手） |
| 有 `transport-up`，没有 `relay.device-attach` | 连上了中转但接入没成功（多为设备凭据被撤销或过期） |
| 有 `relay.device-attach`，没有 `device.attach` | 中转收到了、连接器没收到（连接器离线或链路正在重连） |
| 两者都有，随后又出现 `device.attach-again` | 同一台设备同时开了两条 socket（App 在重建链路），旧的会被中转静默顶替 |

**2. 连上耗时长 / 加载慢：卡在哪一段。** 看 `attaches.jsonl` 的 `appStages`
（`dialMs` / `transportUpMs` / `firstRequestMs` / `firstResponseMs` / `helloMs` / `firstScreenMs`）
与 `connectorPhases`。两侧对同一次接入的「拨号→握手」读数应当接近，差值在 `helloSkewMs` 里；
差得多说明归属配错了，而不是系统慢。`missing` 里的阶段是**没发生**，不要当成 0。

**3. 同步慢：取数还是传输。** 看 `request.slow`（连接器侧超过阈值的单次请求：方法名、耗时、字节数）
与 `device.summary`（该次接入的 p50/p95 与最慢三条）；App 侧对应 `app.request`
（每一次交互的耗时与字节）。同一个方法两侧都有数时，比较二者即可分辨是取数慢还是手机侧处理慢。

**4. 记录本身有没有失控。** `coverage.json` 的 `droppedEarlier` 与 `status.json` 里的
`journal.fileErrors` 应保持 0；`coverage.connector.rolledOut` 为真表示更早的事件已被滚动丢弃。

## 三、上限与隐私

- 连接器流水：单文件 256 KiB、滚动保两代；App 侧：128 KiB × 两代；中转沿用系统日志上限。
  三处都有硬上限，写失败只报一次且不影响链路。
- 诊断包里**不出现**凭据、邀请码、消息正文与家目录绝对路径；设备名以 `DSH-` 开头的调试设备
  默认整条排除（显式 `--device` 点名时除外）。这些规则由 `npm run check:diagnostics` 机械核对，
  采集命令写包前也跑一遍同样的检查，命中就不出包。
- 关闭方式：连接器配置 `journalFile: false`（只留内存）或 `slowRequestMs: 0`（不记单条慢请求）。

## 四、相关文档

- 采集命令与诊断包的字段契约：`specs/020-link-diagnostics/contracts/collect-command.md`
- 事件词表：`specs/020-link-diagnostics/contracts/diagnostics-events.md`
- 连接器状态接口：`specs/001-connector-host-compat/contracts/status-endpoint.md`
- 安装与宿主识别：`docs/ONBOARDING.md`
