# relay-go 部署与切换（M5）

本目录是 Go 版中转的部署面：systemd unit、Python ↔ Go 切换脚本与本说明。
协议、构建方式、环境变量、各里程碑的实测数字见 `relay-go/README.md`；迁移与回滚
的总体要求见内部设计记录（`maintainers/`，不随仓库发布）§10。

生产环境是 Alibaba Cloud Linux 3：Python 版在 `/opt/dsh-relay`，unit 是
`dsh-relay.service`，数据库 `/var/lib/dsh-relay/state.db`，Caddy 把
`https://<站点>/dsh-link/*` 反代到 `127.0.0.1:8787`。本目录的脚本**不改 Caddy、
不改 `relay/*.py`**；它只负责在两个 unit 之间切换，安装步骤见 §4。

## 1. 两个 unit 的关系

| 项 | Python 版 | Go 版 |
|---|---|---|
| unit | `dsh-relay.service` | `dsh-relay-go.service` |
| 程序 | `/opt/dsh-relay/.venv/bin/python /opt/dsh-relay/relay.py` | `/opt/dsh-relay-go/bin/dsh-relay serve` |
| 用户 / 组 | `dsh-relay` / `dsh-relay` | 同左 |
| 监听 | `127.0.0.1:8787` | 同左 |
| 数据库 | `/var/lib/dsh-relay/state.db` | 同左 |
| 可写目录 | `/var/lib/dsh-relay` | 同左 |
| 重启策略 | `on-failure`，`RestartSec=2` | 同左 |

两个 unit 共用同一个端口与同一份数据库，**任何时刻只能有一个在跑**。`switch.sh`
在一开始就要求目标 unit 的二进制与 unit 文件存在，停止旧实现后等待端口释放，再启动
目标；启动成功后把目标设为开机自启、把另一个设为不自启，因此重启机器不会出现两个
实现同时抢 8787 的情况。

在 24 小时观察期内，`/opt/dsh-relay` 必须保留：它是回滚目标。M7 起另有两套
Go 的运维 timer（`dsh-relay-go-alerts.*` / `dsh-relay-go-purge.*`），**默认不启用**，
与 Python 的 `dsh-relay-alerts.*` / `dsh-relay-purge.*` 并存；切换步骤见 §10.1。

## 2. 文件与目录

| 路径 | 内容 |
|---|---|
| `/opt/dsh-relay-go/bin/dsh-relay` | Go 二进制（root:root，0755） |
| `/opt/dsh-relay-go/bin/build.json` | 部署指纹，`relayVersion` 读它；必须与二进制同目录 |
| `/etc/systemd/system/dsh-relay-go.service` | 本目录的 unit |
| `/etc/systemd/system/dsh-relay-go-alerts.{service,timer}` | 告警投递（Go，默认不启用；见 §10.1） |
| `/etc/systemd/system/dsh-relay-go-purge.{service,timer}` | 设备死记录清理（Go，默认不启用；见 §10.1） |
| `/var/lib/dsh-relay/state.db` | 两种实现共用的 SQLite 库 |
| `/var/backups/dsh-relay/<UTC 时间>-to-go/` | `--to-go` 的库备份、`MANIFEST`、`SHA256SUMS`、旧 unit 文件 |
| `/var/log/dsh-relay-switch.log` | 切换审计日志（每次 begin / ok / rollback / failed 各一行） |

`build.json` 的格式与 Python 版 `relay/build.json` 相同：

```json
{"version":"20261023.1600","commit":"75ccb49","deployedAt":"2026-10-23T08:00:00Z"}
```

`version` 用北京时间 `yyyyMMdd.HHmm`，与 iOS 构建号同口径；读不到文件时
`/healthz` 的 `relayVersion` 是 `0.0.0`，表示"这不是一次部署"。

## 3. 构建

### 3.1 纯 Go 静态二进制（首次切换推荐）

不依赖 cgo 与目标机 glibc，可在 macOS / Linux 上交叉构建。SQLite 自动退回
`modernc.org/sqlite`，schema、迁移与 SQL 与 cgo 构建完全相同。

```bash
cd relay-go
GOMODCACHE="$PWD/.gocache/mod" GOCACHE="$PWD/.gocache/build" \
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags "-s -w" -o bin/dsh-relay-linux-amd64 ./cmd/dsh-relay

sha256sum bin/dsh-relay-linux-amd64
file bin/dsh-relay-linux-amd64          # ELF 64-bit LSB executable, statically linked
go version -m bin/dsh-relay-linux-amd64 # go1.27.1，依赖含 modernc.org/sqlite
```

本仓库沙箱把 Go 缓存固定在 `.gocache/`（见 `Makefile`）；在正常网络与磁盘环境下可以
去掉 `GOMODCACHE` / `GOCACHE`。`GOSUMDB=off` 只用于本机开发，正式发布构建应保留
默认的模块校验。

### 3.2 目标机 cgo 构建

`CGO_ENABLED=1` 时用 `mattn/go-sqlite3`，需要 C 工具链，二进制动态链接目标机 glibc。
在目标机或与目标机 glibc 匹配的 Linux CI 上构建：

```bash
# Alibaba Cloud Linux 3（只示例，按最小权限与变更流程执行）
sudo dnf install -y gcc make
cd relay-go
make build            # 产出 bin/dsh-relay
file bin/dsh-relay    # dynamically linked
ldd bin/dsh-relay     # 应只依赖目标机已有的 libc / libpthread / libdl
```

M4b 已记录：从 macOS 交叉编译 cgo（`CGO_ENABLED=1 GOOS=linux`）失败，原因是本机没有
Linux 交叉 C 工具链（108 行 `gcc_amd64.S` 错误），与 relay 代码无关。因此 cgo 形态
只能在 Linux 上构建，或在带 `x86_64-linux-gnu-gcc` / musl / zig 的机器上构建。

### 3.3 两种形态怎么选

| 维度 | 纯 Go（modernc） | cgo（mattn） |
|---|---|---|
| 产物 | 静态 ELF，无 glibc 依赖；M5 构建 13.3 MiB（`-s -w`） | 动态链接；M0 基准 7.62 MiB，M5 未产出 Linux cgo 全功能产物 |
| 构建 | 任意平台交叉编译 | 需要 Linux C 工具链，GLIBC 需与目标机匹配 |
| 单条插入 | 61.90 µs（中位数） | 14.73 µs（快 76%） |
| 16 并发读 | 283,221 ops/s | 616,283 ops/s（快 118%） |
| 16 并发读 p99 | 0.224 ms | 0.339 ms |
| 产品负载下的意义 | 100 设备 × 10 fps 只需约 1,000 帧/秒，驱动不是瓶颈 | 余量更大，适合 DB 写入成为瓶颈时 |

数字来自内部驱动基准（同一 schema、同一 WAL /
`busy_timeout` 设置，各跑三次取中位数）。选择规则：

- **首次切换用纯 Go 静态二进制**：目标机不需要装 Go 工具链，构建可复现，失败时
  二进制本身不引入 glibc 变量。M5 只验证了这一形态的 Linux 产物。
- 24 小时观察中若确认 DB 是瓶颈（`database is locked`、写事务等待、`/stats` 的
  运维面明显变慢），再在目标机本机构建 cgo 版本替换同一个路径并重启；两种形态的
  参数、schema 与 `/healthz` 输出相同，切换方式不变。
- 不要在一个观察窗口内同时更换"实现语言 + 驱动"，否则回滚时无法区分变量。

## 4. 首次安装（只安装，不启动）

前提：Python 版正在运行；已按 §3 产出 Linux 二进制。

```bash
# 1. 目录与二进制
sudo install -d -m 0755 -o root -g root /opt/dsh-relay-go/bin
sudo install -m 0755 -o root -g root \
  relay-go/bin/dsh-relay-linux-amd64 /opt/dsh-relay-go/bin/dsh-relay

# 2. 部署指纹（与二进制同目录）
version="$(TZ=Asia/Shanghai date +%Y%m%d.%H%M)"
commit="$(git -C . rev-parse --short HEAD 2>/dev/null || true)"
sudo tee /opt/dsh-relay-go/bin/build.json >/dev/null <<EOF
{"version":"$version","commit":"$commit","deployedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
sudo chmod 0644 /opt/dsh-relay-go/bin/build.json

# 3. unit（运维 timer 也装上，但**不启用**：见 §10.1 的切换顺序）
sudo install -m 0644 relay-go/deploy/dsh-relay-go.service \
  /etc/systemd/system/dsh-relay-go.service
sudo install -m 0644 \
  relay-go/deploy/dsh-relay-go-alerts.service relay-go/deploy/dsh-relay-go-alerts.timer \
  relay-go/deploy/dsh-relay-go-purge.service  relay-go/deploy/dsh-relay-go-purge.timer \
  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl cat dsh-relay-go.service >/dev/null && echo "unit installed"
# Linux 上再做一次语法/依赖校验；没有 systemd-analyze 的机器跳过
sudo systemd-analyze verify /etc/systemd/system/dsh-relay-go.service || true
sudo systemd-analyze verify /etc/systemd/system/dsh-relay-go-alerts.service || true
sudo systemd-analyze verify /etc/systemd/system/dsh-relay-go-purge.service || true

# 4. 只做本机冒烟：--help 不碰数据库、不监听端口
sudo /opt/dsh-relay-go/bin/dsh-relay --help | head -20
sudo /opt/dsh-relay-go/bin/dsh-relay admin --help | head -20
# 两个运维子命令：一个只读队列（--dry-run 不动队列），一个只预演（不给 --apply 不改库）
sudo DLP_ALERT_DIR=/var/lib/dsh-relay/alerts \
  /opt/dsh-relay-go/bin/dsh-relay alert-dispatch --dry-run | head -20
sudo /opt/dsh-relay-go/bin/dsh-relay purge \
  --db /var/lib/dsh-relay/state.db --all-agents | head -c 800
```

**不要**在此时 `systemctl enable/start dsh-relay-go`：8787 还被 Python 占用。
`switch.sh --to-go` 会在 Go 健康检查通过后才启动并设为开机自启。若在安装与切换之间
机器重启，Python 仍是唯一启用项，服务不受影响。

## 5. 切换前记录基线

低峰窗口执行；切换会让现有 WebSocket 断开一次（客户端会自动重连）。先留一份 Python
的 24 小时基线，后续断连率、5xx 与配对失败率都按同口径比较：

```bash
sudo systemctl show -p ActiveState -p MainPID -p NRestarts dsh-relay
curl -s --noproxy '*' http://127.0.0.1:8787/healthz | python3 -m json.tool
curl -s --noproxy '*' http://127.0.0.1:8787/stats > /tmp/python-stats-before.json
sudo journalctl -u dsh-relay --since '24 hours ago' --no-pager > /tmp/python-24h.log
grep -c 'agent disconnected' /tmp/python-24h.log || true
grep -c 'request failed' /tmp/python-24h.log || true

# 库与备份空间
df -Pk /var/backups/dsh-relay /var/lib/dsh-relay
sudo /opt/dsh-relay/.venv/bin/python - <<'PY'
import sqlite3
con = sqlite3.connect("file:/var/lib/dsh-relay/state.db?mode=ro", uri=True)
print("quick_check", con.execute("PRAGMA quick_check").fetchone()[0])
print("user_version", con.execute("PRAGMA user_version").fetchone()[0])
con.close()
PY
```

## 6. 执行切换

```bash
sudo relay-go/deploy/switch.sh --to-go
```

脚本按固定顺序做：

1. 预检：root、`systemctl` / `ss` / `curl` / `flock`、Go unit 与二进制、数据库存在、
   审计日志可写、备份空间约为库大小的两倍加 10 MiB；
2. 幂等判断：Go unit 已健康则只补 enable/disable，不重启、不新增备份；
3. 停 `dsh-relay.service` 与残留的 `dsh-relay-go.service`（目标若卡死也一并停），
   等待 8787 释放（默认最多 20 秒）；
4. `PRAGMA wal_checkpoint(TRUNCATE)`，要求 `busy=0` 且 `-wal` 为空；
5. 把库复制到 `/var/backups/dsh-relay/<UTC>-to-go/`，校验 `integrity_check`、
   `user_version`、sha256，写 `MANIFEST` 与 `SHA256SUMS`；
6. 启动 `dsh-relay-go.service`，等待 `/healthz`、`/dsh-link/healthz`、`/stats` 全部
   `ok`，并核对 unit 的 MainPID 就是 8787 的监听进程；
7. 启用 Go、停用 Python，写审计 `phase=ok`。

任何一步失败都会写 `phase=failed`，然后停掉 Go、重新启动 Python 并做同样的健康检查；
回滚成功写 `phase=rollback-ok`。退出码：

| 退出码 | 含义 |
|---|---|
| 0 | 切换成功，或目标已经健康（幂等 no-op） |
| 1 | 切换失败；脚本已尝试回滚，输出与审计日志里有原因 |
| 2 | 用法或前置条件不满足；**没有动服务** |

`--to-go` 不会替换二进制，也不会替你保留上一份 Go 二进制。更新 Go 版本时：先把
旧的 `/opt/dsh-relay-go/bin/dsh-relay` 复制到版本目录留档，再安装新二进制与
`build.json`，然后 `systemctl restart dsh-relay-go`（或先 `--to-python` 再
`--to-go`，后者会多一次数据库备份）。
若只是想验证"新二进制能否启动"，用 `DSH_RELAY_GO_BIN=/path/to/new --to-go` 不会生效，
因为 unit 的 ExecStart 指向固定路径；请在目标机替换后再重启。

切换完成后立即验证：

```bash
sudo relay-go/deploy/switch.sh --status
curl -s --noproxy '*' http://127.0.0.1:8787/healthz | python3 -m json.tool
curl -s --noproxy '*' http://127.0.0.1:8787/stats | python3 -m json.tool | head -40
sudo journalctl -u dsh-relay-go -n 50 --no-pager
```

`relayVersion` 应等于刚写入 `build.json` 的 `version`；`/stats` 的 `load.devices`
应在真实设备重连后恢复。公网面从工作站验证一次
`https://<站点>/dsh-link/healthz`，并让一台真实设备完成一次重连与消息往返。

## 7. 24 小时观察与回滚阈值

观察期按 M4b 的稳态数字定基线：100 设备 × 10 fps 时 RSS 约 55 MiB、goroutine 252、
p99 0.555 ms、丢帧 0；1000 设备档 RSS 182 MiB、丢帧 0。生产设备数通常低于 100。
**硬阈值**任意一条命中即回滚；**软阈值**同一小时内出现两条也回滚，单条先排查。

| 观测项 | 采集方式 | 正常 | 硬阈值（回滚） | 软阈值 |
|---|---|---|---|---|
| 进程 | `systemctl is-active dsh-relay-go`；`systemctl show -p NRestarts` | active，`NRestarts=0` | inactive，或 10 分钟内重启 ≥ 3 次 | 重启 1 次后稳定 |
| `/healthz` | 每 10 秒 `curl -fsS --noproxy '*' .../healthz` | 全部 200 且 `ok:true` | 连续 3 次失败，或 1 分钟内 ≥ 3 次失败 | 单次失败 |
| `/stats` | 同上，访问 `/stats` | 200 且 `ok:true` | 连续 3 次失败 | 响应持续 > 1 s |
| 5xx | `journalctl ... \| grep -c 'request failed'`；`alerts.jsonl` 里的 5xx 类别 | 稳态 0 | 5 分钟内 ≥ 1 次/分钟，或 1 分钟内 ≥ 10 次 | 出现单条 5xx |
| DB 锁 | `journalctl ... \| grep -i 'database is locked'`；503 `db/busy` | 0 | 5 分钟内 ≥ 1 次/分钟 | 偶发一次 |
| 连接器断开 | `grep -c 'agent disconnected'` | ≤ Python 24h 基线 | 1 小时内 > 基线的 2 倍；或同一 agent 300 秒内 5 次（flap） | 1.5 倍基线 |
| 心跳失败 | `grep -c 'heartbeat failed'` | 0 | 10 分钟内 ≥ 3 次 | 1 次 |
| 丢帧 | `/stats` 的 `traffic.devices[].droppedFrames` 与 `snapshot.*.droppedFrames` | 0 | 连续 5 分钟增长 | 单次非零 |
| 内存 | `systemctl show -p MemoryCurrent`（空则 `/proc/PID/status` 的 `VmRSS`） | 100 设备约 55 MiB | 持续 10 分钟 > 256 MiB；或预热 1 小时后 > +10 MiB/小时 | > 200 MiB |
| FD | `ls /proc/$(systemctl show -p MainPID --value dsh-relay-go)/fd \| wc -l` | 随连接数稳定 | 1 小时增长 > 100 | 1 小时增长 > 50 |
| 告警队列 | `wc -l /var/lib/dsh-relay/alerts/alerts.jsonl` | 平缓、无新类别 | 持续增长且 > 50 条 | 出现新类别或 > 20 条/小时 |
| 数据完整性 | `PRAGMA quick_check`（只读） | `ok` | 不是 `ok` | — |
| 用户侧 | App 重连、消息往返、反馈提交 | 正常 | 确认一次消息丢失或持续重连失败 | 偶发重连 |

采集命令（观察期每天至少一次，切换后 1 小时内每 15 分钟一次）：

```bash
sudo journalctl -u dsh-relay-go --since '24 hours ago' --no-pager > /tmp/go-24h.log
for pat in 'request failed' 'agent disconnected' 'device detached' \
           'heartbeat failed' 'database is locked' 'device exceeded its daily allowance'; do
  printf '%-40s %s\n' "$pat" "$(grep -c "$pat" /tmp/go-24h.log || true)"
done

curl -s --noproxy '*' http://127.0.0.1:8787/stats > /tmp/go-stats.json
python3 - <<'PY'
import json
data = json.load(open("/tmp/go-stats.json"))
print("agents/devices:", data["load"]["agents"], data["load"]["devices"])
print("egress bytes:", data["traffic"]["totalEgressBytes"])
print("dropped frames:", sum(item.get("droppedFrames", 0) for item in data["traffic"]["devices"]))
print("bridge in use:", sum(item.get("bridgeBytesInUse", 0) for item in data["snapshot"]["agents"]))
PY

pid="$(systemctl show -p MainPID --value dsh-relay-go)"
grep -E 'VmRSS|VmPeak' "/proc/$pid/status"
ls "/proc/$pid/fd" | wc -l
systemctl show -p MemoryCurrent -p NRestarts -p ActiveState dsh-relay-go

if [ -f /var/lib/dsh-relay/alerts/alerts.jsonl ]; then
  wc -l /var/lib/dsh-relay/alerts/alerts.jsonl
else
  echo "0 alerts"
fi

sudo -u dsh-relay /opt/dsh-relay/.venv/bin/python - <<'PY'
import sqlite3
con = sqlite3.connect("file:/var/lib/dsh-relay/state.db?mode=ro", uri=True)
print("quick_check", con.execute("PRAGMA quick_check").fetchone()[0])
con.close()
PY
```

24 小时内不做第二次部署；不启用 pprof 取性能数字（采样本身有开销）；任何回滚先记录
时间、原因、当时 `/stats` 与最近 200 行日志，再重试。

## 8. 回滚

### 8.1 自动回滚

`--to-go` 的健康检查失败会自动执行 `--to-python` 的等价动作（停 Go、启动 Python、
健康检查），并把原因写进审计日志。`--to-python` 失败默认回滚到 Go，避免把服务留在
停止状态；若明确不想回到 Go，用：

```bash
sudo DSH_RELAY_AUTO_ROLLBACK=0 relay-go/deploy/switch.sh --to-python
```

### 8.2 用脚本回滚

```bash
sudo relay-go/deploy/switch.sh --to-python
sudo relay-go/deploy/switch.sh --status
```

目标 5 分钟。M4b 的本机演练（同一临时库、同一端口）实测 Go → Python 111 ms、
Python → Go 32 ms；这是进程切换时间，不含人工判断与公网验证，不能当作生产 SLA。

### 8.3 脚本不可用时的兜底

```bash
sudo systemctl stop dsh-relay-go
sudo systemctl start dsh-relay
sudo systemctl status dsh-relay --no-pager
curl -s --noproxy '*' http://127.0.0.1:8787/healthz | python3 -m json.tool
sudo systemctl enable dsh-relay
sudo systemctl disable dsh-relay-go
```

### 8.4 数据库恢复（仅当库损坏）

`switch.sh` 的备份在 `/var/backups/dsh-relay/<UTC>-to-go/`。恢复会丢弃备份之后的
写入，只在 `quick_check` 失败或明确的数据损坏时使用：

```bash
sudo systemctl stop dsh-relay-go dsh-relay
backup=/var/backups/dsh-relay/<UTC>-to-go
( cd "$backup" && sudo sha256sum -c SHA256SUMS )
sudo install -m 0600 -o dsh-relay -g dsh-relay "$backup/state.db" /var/lib/dsh-relay/state.db
sudo rm -f /var/lib/dsh-relay/state.db-wal /var/lib/dsh-relay/state.db-shm
sudo systemctl start dsh-relay
curl -s --noproxy '*' http://127.0.0.1:8787/healthz
```

若必须在 Go 上恢复，把 `start dsh-relay` 换成 `start dsh-relay-go`；schema 与
`user_version` 两种实现相同（8），不需要转换库。

## 9. 回滚演练

### 9.1 本机自动演练（不碰生产）

```bash
# 需要当前平台的 Go 二进制；本机是 macOS 时 make build 产出 darwin 版本
cd relay-go && make build
cd ..
relay/.venv/bin/python relay-go/scripts/m4b/rollback_drill.py
```

脚本用临时库、随机端口，按 Go → Python → Go 各切一次，核对账户、设备、账户状态
双向可读，并打印每次切换耗时；全部断言通过时退出码为 0，失败会抛 `StepFailure`
并以非零退出。

### 9.2 生产低峰演练（切换前或观察期内）

```bash
sudo relay-go/deploy/switch.sh --to-go
sudo relay-go/deploy/switch.sh --status
sudo relay-go/deploy/switch.sh --to-python
sudo relay-go/deploy/switch.sh --status
sudo relay-go/deploy/switch.sh --to-go
grep 'phase=ok' /var/log/dsh-relay-switch.log | tail -3
```

每步之间确认一台真实设备能重连、`/stats` 的 `load.devices` 能恢复。切换耗时从审计
日志的 `duration_s` 读取；若任一步超过 5 分钟，先查原因再继续，不要靠重试掩盖。

数据面核对（两种 admin 读同一份库）：

```bash
sudo /opt/dsh-relay-go/bin/dsh-relay admin --db /var/lib/dsh-relay/state.db \
  usage --days 1 --by account > /tmp/go-usage.json
sudo /opt/dsh-relay/.venv/bin/python /opt/dsh-relay/admin.py \
  --db /var/lib/dsh-relay/state.db usage --days 1 --by account > /tmp/py-usage.json
python3 -m json.tool /tmp/go-usage.json > /tmp/go-usage.pretty
python3 -m json.tool /tmp/py-usage.json > /tmp/py-usage.pretty
diff -u /tmp/py-usage.pretty /tmp/go-usage.pretty || true
```

两者字段口径一致；若只有顺序或浮点尾数不同，按实际差异记录，不要直接忽略。

## 10. 已知边界与后续项

1. **单端口，无按 agent 灰度**：切换会断开所有在线 WebSocket；只能靠低峰窗口、
   备份与回滚速度控制影响。客户端会自动重连，但正在传输的文件会中断，需要重试。
   备份包含一次 `integrity_check`，库很大时会拉长窗口；切换前用 `du -h` 估时。
2. **2 小时 soak 未跑**：M4b 跑的是 180 s 与 600 s；小时级缓慢泄漏没有被排除。
   24 小时观察里的 RSS/FD 趋势是这一项的实际替代证据。
3. **APNs 真实联调未做**：M3b2 只用注入桩验证，未调用 Apple。unit 默认
   `DLP_APNS_ENABLED=0`；打开前先看 `relay-go/README.md` 的推送章节与 24 小时
   日志里的 `push failed`。
4. **Go 运维 timer 已交付但默认未启用**：`dsh-relay-go-alerts.*` 调
   `dsh-relay alert-dispatch`，`dsh-relay-go-purge.*` 调 `dsh-relay purge`；两套 unit
   与 Python 的 `dsh-relay-alerts.*` / `dsh-relay-purge.*` 独立命名，切换顺序见
   §10.1。在启用前 Python timer 仍负责告警投递与清理，不要两套同时开——同一队列被
   投递两次。
5. **`/stats` 的 HTML 页是本机运维面**：`Accept: text/html` 时渲染与 Python 同口径的
   页面（连接数、限额、设备流量、今日用量）；Caddy 对公网 `/dsh-link/stats` 仍然回
   404，页面只从主机环回读。
6. **cgo 产物未在 Linux 上实际运行**：M5 只验证纯 Go 静态 ELF。若改用 cgo，先在
   目标机做一次 `dsh-relay --help`、临时库启动与 `/healthz` 检查，再替换生产二进制。
7. **Linux 产物未在目标机实跑**：M5 只做 ELF/元数据核验，以及在 macOS 上用同一份
   源码的 darwin 产物冒烟 `/healthz`、`/dsh-link/healthz`、`/stats`。首次
   `switch.sh --to-go` 就是它第一次在 Alibaba Cloud Linux 3 上启动；健康检查失败会
   在 30 秒内回滚，但仍应在低峰窗口首次切换。
8. **systemd 沙箱沿用 Python unit**：`SystemCallFilter=@system-service`、
   `MemoryDenyWriteExecute` 等逐项照搬。Go 运行时若被 seccomp 拒绝，日志里会是
   `operation not permitted`，切换会按失败回滚；届时按实际 syscall 调整白名单，
   不要为了启动服务直接清空 `SystemCallFilter`。
9. **`switch.sh` 不做安装**：它不复制二进制、不生成 `build.json`、不改 Caddy；
   安装步骤见 §4。`--to-go` 也不负责升级已运行的二进制（见 §6 末尾）。
10. **审计日志只追加**：没有轮转；按 `/var/log` 的现有策略处理，或后续加 logrotate。

### 10.1 Go 运维 timer（M7 交付，默认不启用）

四个 unit 已随仓库交付，但在生产**不要**在切换当天直接启用；建议顺序：

```bash
# 1. 预演两个动作（手工跑二进制；service 里的 ExecStart 带 --apply，别拿它预演）
sudo /opt/dsh-relay-go/bin/dsh-relay purge \
  --db /var/lib/dsh-relay/state.db --all-agents | head -c 800
sudo DLP_ALERT_DIR=/var/lib/dsh-relay/alerts \
  /opt/dsh-relay-go/bin/dsh-relay alert-dispatch --dry-run | head -40
# 预演确认后，可以手工真跑一次清理（与 timer 的 ExecStart 相同）：
#   sudo systemctl start dsh-relay-go-purge.service
#   sudo journalctl -u dsh-relay-go-purge -n 30 --no-pager

# 2. 接替 Python 的 timer（先停旧的，再开新的；同一时刻只留一套）
sudo systemctl disable --now dsh-relay-alerts.timer dsh-relay-purge.timer
sudo systemctl enable --now dsh-relay-go-alerts.timer dsh-relay-go-purge.timer

# 3. 回滚：换回来即可，队列与库都没被改写
sudo systemctl disable --now dsh-relay-go-alerts.timer dsh-relay-go-purge.timer
sudo systemctl enable --now dsh-relay-alerts.timer dsh-relay-purge.timer
```

注意 `dsh-relay purge` 是 `purge-revoked-devices.py` 的 Go 版本（删设备死记录），
与 `dsh-relay admin purge`（删过期配对码）不是同一件事；两者都不带 `--apply` 时只
预演。`--keep 14` 只清理由本工具命名的旧备份。

### 10.2 `/stats` 运维页

```bash
curl -s localhost:8787/stats | head -c 400                  # JSON（脚本用）
curl -s -H 'Accept: text/html' localhost:8787/stats | head  # 页面（浏览器打开同一 URL）
```

页面与 JSON 读同一份 `statsResponse`：本次连接数、限额、死设备记录、每设备本次出口
与被限速时长、今日用量，外加 M7 的连接生命周期计数（顶替、重复连接抑制、未上报版本
的在线连接）。只允许环回来源，与非 HTML 请求共用同一道守卫。

## 11. 故障排查

| 现象 | 先看 | 处理 |
|---|---|---|
| `switch.sh: 找不到 dsh-relay-go.service` | `systemctl cat dsh-relay-go.service` | 按 §4 安装 unit 并 `daemon-reload` |
| `Go 二进制不存在或不可执行` | `ls -l /opt/dsh-relay-go/bin/dsh-relay` | 重新安装 0755 二进制 |
| `数据库不存在` | `ls -l /var/lib/dsh-relay/state.db` | 首次部署不要走切换；确认数据目录与 unit 的 `--db` 一致 |
| `端口 8787 未释放` | `ss -lntp 'sport = :8787'` | 找出占用进程；不要盲目 kill，先确认它是不是旧 unit 的残留 |
| `Go 健康检查未通过` | `journalctl -u dsh-relay-go -n 100`；手工 `curl /healthz` | 看 DB 权限、`build.json`、端口；脚本已自动回滚 |
| `/healthz` 的 `relayVersion=0.0.0` | `ls -l /opt/dsh-relay-go/bin/build.json` | `build.json` 必须与二进制同目录；内容需是合法 JSON |
| `/stats` 404 | 请求来源是不是环回 | Go 与 Python 都只允许环回；从主机 shell 读 |
| `systemctl reload dsh-relay-go` 报不支持 | unit 没有 `ExecReload` | 这是刻意设计：SIGHUP 会终止 Go 进程；用 `restart` |
| 两个 unit 同时 active/enabled | `switch.sh --status`；`systemctl is-enabled` | 手工 `disable` 错误的一项；正常路径由 `switch.sh` 维护 |
| 公网 `/dsh-link/healthz` 502 | `journalctl -u caddy -n 50`；`ss` 看 8787 | 本脚本不碰 Caddy；先确认 Go 在本机 200，再查反代 |
| 告警 timer 在 Go 切换后失败 | `journalctl -u dsh-relay-go-alerts -n 50`；先手工跑 §10.1 的 `--dry-run` | 检查 `alert.env` 的收件账号与 mail 路径；回退见 §10.1 |
| `purge` 报「数据库不可读」 | `ls -l /var/lib/dsh-relay/state.db`；unit 的 `--db` | 路径必须与 `dsh-relay-go.service` 一致；不要在缺库的机器上跑 |
| `/stats` 打开仍是 JSON | 请求头有没有 `Accept: text/html` | 浏览器默认带；`curl` 需要显式 `-H` |
| `database is locked` 增多 | `journalctl`、`/stats`、`quick_check` | 按 §7 的硬阈值回滚；不要用重启掩盖 |

## 12. 本次交付的验证记录

2026-10-23，本机（macOS，Go 1.27.1）执行：

- `bash -n relay-go/deploy/switch.sh` 通过；
- 本机没有 `systemd-analyze`，改用逐项文本对齐：`Type`、`User`、`Group`、
  `Restart`、`RestartSec`、`TimeoutStopSec`、全部沙箱与路径指令、
  `StateDirectory`、`ReadWritePaths`、`LimitNOFILE` 以及 `EnvironmentFile`
  与 `relay/deploy/dsh-relay.service` 逐项相同（共 35 个指令；`WorkingDirectory`
  按预期分别是 `/opt/dsh-relay` 与 `/opt/dsh-relay-go`）；
- 11 个共有 `DLP_*` 环境变量取值全等。差异均为有意：Go 把 host/port/db/base-path
  放在 `ExecStart`（不再重复 `DLP_HOST` 等四个变量）、没有
  `PYTHONDONTWRITEBYTECODE`、没有 `ExecReload`（SIGHUP 会终止 Go 进程）、多一个
  `DLP_ALERT_SURROGATE_SAMPLES`；
- `ExecStart` 的 `--host` / `--port` / `--db` 与 Python 相同，
  `--base-path /dsh-link` 与 Python 的 `DLP_BASE_PATH` 取值相同；
- 用 systemctl/ss/curl/flock 桩跑切换控制流 38 项断言全部通过（覆盖双向成功切换、
  双向幂等 no-op、双向失败回滚、缺二进制、缺数据库）；
- `CGO_ENABLED=0 GOOS=linux GOARCH=amd64` 交叉构建成功：
  `bin/dsh-relay-linux-amd64`，sha256
  `b87a806b614e0097986d2f40c85e8630e1ff7e2786298c7ab140ceae571d172c`，
  静态 ELF x86-64，`stripped`，`go1.27.1`；同一命令再构建一次，sha256 相同；
- 全量黑盒结果沿用 M4b 内部报告：117 passed + 1 xpassed。

该 sha256 是本机这次构建的产物标识；重新构建（换 Go 版本或改源码）会变。生产部署时
用 `sha256sum` 记录实际安装的那一份，并可用
`DSH_RELAY_GO_SHA256=<hex> switch.sh --to-go` 让脚本在启动前校验。
