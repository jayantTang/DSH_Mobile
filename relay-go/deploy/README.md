# relay-go 部署

本目录是 Go 版中转的部署面：systemd unit、Caddy 片段与插入工具、部署说明。
协议、构建方式、环境变量见 `relay-go/README.md`。

生产环境是 Alibaba Cloud Linux 3：程序在 `/opt/dsh-relay-go`，unit 是
`dsh-relay-go.service`，数据库 `/var/lib/dsh-relay/state.db`，Caddy 把
`https://<站点>/dsh-link/*` 反代到 `127.0.0.1:8787`。

## 1. 文件与目录

| 路径 | 内容 |
|---|---|
| `/opt/dsh-relay-go/bin/dsh-relay` | Go 二进制（root:root，0755） |
| `/opt/dsh-relay-go/bin/build.json` | 部署指纹，`relayVersion` 读它；必须与二进制同目录 |
| `/opt/dsh-relay-go/bin/history/<version>/` | 升级时留档的上一份二进制 |
| `/etc/systemd/system/dsh-relay-go.service` | 主服务 unit |
| `/etc/systemd/system/dsh-relay-go-alerts.{service,timer}` | 告警投递（默认不启用，见 §6） |
| `/etc/systemd/system/dsh-relay-go-purge.{service,timer}` | 设备死记录清理（默认不启用，见 §6） |
| `/etc/dsh-relay/apns.env` | APNs 配置，模板是本目录的 `apns.env.example` |
| `/etc/dsh-relay/alert.env` | 告警收件账号，模板是本目录的 `alert.env.example` |
| `/var/lib/dsh-relay/state.db` | SQLite 库 |
| `/var/lib/dsh-relay/alerts/alerts.jsonl` | 告警队列（`alert-dispatch` 读取） |

`build.json` 格式：

```json
{"version":"20261023.1600","commit":"75ccb49","deployedAt":"2026-10-23T08:00:00Z"}
```

`version` 用北京时间 `yyyyMMdd.HHmm`，与 iOS 构建号同口径；读不到文件时
`/healthz` 的 `relayVersion` 是 `0.0.0`，表示"这不是一次部署"。

## 2. 构建

### 2.1 纯 Go 静态二进制（推荐）

不依赖 cgo 与目标机 glibc，可在 macOS / Linux 上交叉构建。SQLite 使用
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

本仓库沙箱把 Go 缓存固定在 `.gocache/`（见 `Makefile`）；正常环境下可以去掉
`GOMODCACHE` / `GOCACHE`。`GOSUMDB=off` 只用于本机开发，正式发布构建应保留默认校验。

### 2.2 目标机 cgo 构建

`CGO_ENABLED=1` 时用 `mattn/go-sqlite3`，需要 C 工具链，二进制动态链接目标机 glibc：

```bash
# Alibaba Cloud Linux 3（只示例，按最小权限与变更流程执行）
sudo dnf install -y gcc make
cd relay-go
make build            # 产出 bin/dsh-relay
file bin/dsh-relay    # dynamically linked
ldd bin/dsh-relay     # 应只依赖目标机已有的 libc / libpthread / libdl
```

从 macOS 交叉编译 cgo（`CGO_ENABLED=1 GOOS=linux`）会失败：本机没有 Linux 交叉 C
工具链。cgo 形态只能在 Linux 上构建，或在带 `x86_64-linux-gnu-gcc` / musl / zig 的
机器上构建。

### 2.3 两种形态怎么选

| 维度 | 纯 Go（modernc） | cgo（mattn） |
|---|---|---|
| 产物 | 静态 ELF，无 glibc 依赖；`-s -w` 后 13.3 MiB | 动态链接；`-s -w` 后 7.62 MiB |
| 构建 | 任意平台交叉编译 | 需要 Linux C 工具链，GLIBC 需与目标机匹配 |
| 单条插入 | 61.90 µs（中位数） | 14.73 µs（快 76%） |
| 16 并发读 | 283,221 ops/s | 616,283 ops/s（快 118%） |
| 16 并发读 p99 | 0.224 ms | 0.339 ms |
| 产品负载下的意义 | 100 设备 × 10 fps 只需约 1,000 帧/秒，驱动不是瓶颈 | 余量更大，适合 DB 写入成为瓶颈时 |

数字来自内部驱动基准（同一 schema、同一 WAL / `busy_timeout` 设置，各跑三次取中位数）。
选择规则：

- **默认用纯 Go 静态二进制**：目标机不需要装 Go 工具链，构建可复现，不引入 glibc 变量。
- 若确认 DB 是瓶颈（`database is locked`、写事务等待、`/stats` 明显变慢），再在目标机
  本机构建 cgo 版本替换同一个路径并重启；两种形态的参数、schema 与 `/healthz` 输出相同。
- 不要在同一次升级里同时更换"驱动 + 其他变量"，否则回滚时无法区分原因。

## 3. 安装与启动

前提：已按 §2 产出 Linux 二进制，且 `/var/lib/dsh-relay/state.db` 已就位（新装机器可空库）。

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

# 3. 配置模板：只在文件不存在时写入，已有值绝不覆盖
sudo install -d -m 0750 /etc/dsh-relay
[ -e /etc/dsh-relay/apns.env ] || sudo install -m 0640 relay-go/deploy/apns.env.example /etc/dsh-relay/apns.env
[ -e /etc/dsh-relay/alert.env ] || sudo install -m 0640 relay-go/deploy/alert.env.example /etc/dsh-relay/alert.env

# 4. unit（运维 timer 也装上，但默认不启用：见 §6）
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

# 5. 本机冒烟：--help 不碰数据库、不监听端口
sudo /opt/dsh-relay-go/bin/dsh-relay --help | head -20
sudo /opt/dsh-relay-go/bin/dsh-relay admin --help | head -20

# 6. 启动并设开机自启
sudo systemctl enable --now dsh-relay-go
curl -s --noproxy '*' http://127.0.0.1:8787/healthz | python3 -m json.tool
```

`/healthz` 的 `relayVersion` 应等于刚写入 `build.json` 的 `version`；`/stats` 只允许
环回来源读取（见 §7）。公网面从工作站验证一次 `https://<站点>/dsh-link/healthz`，
并让一台真实设备完成一次重连与消息往返。

## 4. Caddy 路由

路由片段是 `relay-go/deploy/Caddyfile.snippet`，由 `relay-go/deploy/caddy_splice.py`
插进既有站点块（幂等，重复执行只替换标记块）：

```bash
sudo python3 relay-go/deploy/caddy_splice.py insert \
  /etc/caddy/Caddyfile relay-go/deploy/Caddyfile.snippet relay.example.com
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

两个标记注释（`# >>> dsh-relay managed block ... >>>` / `# <<< ... <<<`）是生产
Caddyfile 里已经在用的，**不要改文字**：改了之后插入会变成新增一块，旧的不会被替换。
撤销用 `caddy_splice.py remove /etc/caddy/Caddyfile`，或手工删掉标记块。

片段的取值规则见文件内注释：`/dsh-link/*` 用 `handle_path` 剥前缀反代到 8787；
`/dsh-link/stats` 与 `/stats` 在公网回 404；整段必须在既有 catch-all `handle` 之前。

## 5. 升级与回滚

升级只替换二进制与 `build.json`，不换数据库：

```bash
# 1. 留档当前版本（版本号取当前 build.json）
sudo mkdir -p /opt/dsh-relay-go/bin/history
sudo install -d -m 0755 /opt/dsh-relay-go/bin/history/$(python3 -c \
  'import json;print(json.load(open("/opt/dsh-relay-go/bin/build.json"))["version"])')
sudo cp -a /opt/dsh-relay-go/bin/dsh-relay /opt/dsh-relay-go/bin/build.json \
  /opt/dsh-relay-go/bin/history/<当前版本>/

# 2. 备份库（WAL 模式下先 checkpoint）
sudo -u dsh-relay /usr/bin/python3 - <<'PY'
import sqlite3
con = sqlite3.connect("/var/lib/dsh-relay/state.db")
print("checkpoint", con.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone())
print("quick_check", con.execute("PRAGMA quick_check").fetchone()[0])
con.close()
PY
sudo install -d -m 0750 /var/backups/dsh-relay
sudo -u dsh-relay sqlite3 /var/lib/dsh-relay/state.db \
  ".backup /var/backups/dsh-relay/state-$(date -u +%Y%m%dT%H%M%SZ).db"

# 3. 装新二进制与 build.json（§3 第 1–2 步），然后重启
sudo systemctl restart dsh-relay-go
curl -s --noproxy '*' http://127.0.0.1:8787/healthz | python3 -m json.tool
```

回滚 = 把 `history/<版本>/` 里的二进制与 `build.json` 复制回去，`systemctl restart`，
再核一次 `/healthz` 与真实设备重连。退出码与耗时以 `systemctl status` 与日志为准；
不要用多次重启掩盖启动失败。

只有 `quick_check` 失败或明确的数据损坏才恢复数据库：停服务，用备份覆盖
`state.db`，删除 `-wal` / `-shm`，再启动。恢复会丢掉备份之后的写入。

## 6. 运维 timer（默认不启用）

四个 unit 随仓库交付；首次部署先预演两个动作，再启用：

```bash
# 1. 预演（service 的 ExecStart 带 --apply，别拿它预演）
sudo /opt/dsh-relay-go/bin/dsh-relay purge \
  --db /var/lib/dsh-relay/state.db --all-agents | head -c 800
sudo DLP_ALERT_DIR=/var/lib/dsh-relay/alerts \
  /opt/dsh-relay-go/bin/dsh-relay alert-dispatch --dry-run | head -40

# 2. 启用
sudo systemctl enable --now dsh-relay-go-alerts.timer dsh-relay-go-purge.timer
```

`dsh-relay purge` 删设备死记录，与 `dsh-relay admin purge`（删过期配对码）不是同一件事；
两者不带 `--apply` 时只预演。`--keep 14` 只清理由本工具命名的旧备份。

## 7. 观察阈值

观察期每天至少采集一次，升级后 1 小时内每 15 分钟一次。**硬阈值**任意一条命中即回滚；
**软阈值**同一小时内出现两条也回滚，单条先排查。

| 观测项 | 采集方式 | 正常 | 硬阈值 | 软阈值 |
|---|---|---|---|---|
| 进程 | `systemctl is-active dsh-relay-go`；`systemctl show -p NRestarts` | active，`NRestarts=0` | inactive，或 10 分钟内重启 ≥ 3 次 | 重启 1 次后稳定 |
| `/healthz` | 每 10 秒 `curl -fsS --noproxy '*' .../healthz` | 全部 200 且 `ok:true` | 连续 3 次失败，或 1 分钟内 ≥ 3 次失败 | 单次失败 |
| `/stats` | 同上，访问 `/stats` | 200 且 `ok:true` | 连续 3 次失败 | 响应持续 > 1 s |
| 5xx | `journalctl ... \| grep -c 'request failed'`；`alerts.jsonl` 里的 5xx 类别 | 稳态 0 | 5 分钟内 ≥ 1 次/分钟，或 1 分钟内 ≥ 10 次 | 出现单条 5xx |
| DB 锁 | `journalctl ... \| grep -i 'database is locked'`；503 `db/busy` | 0 | 5 分钟内 ≥ 1 次/分钟 | 偶发一次 |
| 连接器断开 | `grep -c 'agent disconnected'` | ≤ 上线基线 | 1 小时内 > 基线的 2 倍；或同一 agent 300 秒内 5 次 | 1.5 倍基线 |
| 心跳失败 | `grep -c 'heartbeat failed'` | 0 | 10 分钟内 ≥ 3 次 | 1 次 |
| 丢帧 | `/stats` 的 `traffic.devices[].droppedFrames` 与 `snapshot.*.droppedFrames` | 0 | 连续 5 分钟增长 | 单次非零 |
| 内存 | `systemctl show -p MemoryCurrent`（空则 `/proc/PID/status` 的 `VmRSS`） | 100 设备约 55 MiB | 持续 10 分钟 > 256 MiB；或预热 1 小时后 > +10 MiB/小时 | > 200 MiB |
| FD | `ls /proc/$(systemctl show -p MainPID --value dsh-relay-go)/fd \| wc -l` | 随连接数稳定 | 1 小时增长 > 100 | 1 小时增长 > 50 |
| 告警队列 | `wc -l /var/lib/dsh-relay/alerts/alerts.jsonl` | 平缓、无新类别 | 持续增长且 > 50 条 | 出现新类别或 > 20 条/小时 |
| 数据完整性 | `PRAGMA quick_check`（只读） | `ok` | 不是 `ok` | — |
| 用户侧 | App 重连、消息往返、反馈提交 | 正常 | 确认一次消息丢失或持续重连失败 | 偶发重连 |

采集命令：

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

sudo -u dsh-relay /usr/bin/python3 - <<'PY'
import sqlite3
con = sqlite3.connect("file:/var/lib/dsh-relay/state.db?mode=ro", uri=True)
print("quick_check", con.execute("PRAGMA quick_check").fetchone()[0])
con.close()
PY
```

### 7.1 `/stats` 运维页

```bash
curl -s localhost:8787/stats | head -c 400                  # JSON（脚本用）
curl -s -H 'Accept: text/html' localhost:8787/stats | head  # 页面（浏览器打开同一 URL）
```

页面与 JSON 读同一份 `statsResponse`：本次连接数、限额、死设备记录、每设备本次出口
与被限速时长、今日用量，以及连接生命周期计数。只允许环回来源。

## 8. 故障排查

| 现象 | 先看 | 处理 |
|---|---|---|
| `Go 二进制不存在或不可执行` | `ls -l /opt/dsh-relay-go/bin/dsh-relay` | 重新安装 0755 二进制 |
| `数据库不存在` | `ls -l /var/lib/dsh-relay/state.db` | 确认数据目录与 unit 的 `--db` 一致 |
| 端口 8787 被占用 | `ss -lntp 'sport = :8787'` | 找出占用进程；先确认是不是上一次的残留 |
| 启动即退出 | `journalctl -u dsh-relay-go -n 100`；手工 `curl /healthz` | 看 DB 权限、`build.json`、端口 |
| `/healthz` 的 `relayVersion=0.0.0` | `ls -l /opt/dsh-relay-go/bin/build.json` | `build.json` 必须与二进制同目录且是合法 JSON |
| `/stats` 404 | 请求来源是不是环回 | 只允许环回；从主机 shell 读 |
| `systemctl reload dsh-relay-go` 报不支持 | unit 没有 `ExecReload` | 刻意设计：SIGHUP 会终止 Go 进程；用 `restart` |
| 公网 `/dsh-link/healthz` 502 | `journalctl -u caddy -n 50`；`ss` 看 8787 | 先确认本机 200，再查反代 |
| 告警 timer 失败 | `journalctl -u dsh-relay-go-alerts -n 50`；手工跑 §6 的 `--dry-run` | 检查 `alert.env` 的收件账号与 mail 路径 |
| `purge` 报「数据库不可读」 | `ls -l /var/lib/dsh-relay/state.db`；unit 的 `--db` | 路径必须与 `dsh-relay-go.service` 一致 |
| `/stats` 打开仍是 JSON | 请求头有没有 `Accept: text/html` | 浏览器默认带；`curl` 需要显式 `-H` |
| `database is locked` 增多 | `journalctl`、`/stats`、`quick_check` | 按 §7 的硬阈值回滚；不要用重启掩盖 |

## 9. 交付验证记录

- 2026-10-24 生产切换，Alibaba Cloud Linux 3，纯 Go 静态二进制；1000 设备长稳与 2 小时
  soak 均在生产同款二进制上通过，详见 `maintainers/发布记录/20261024-Go中转上线.md`。
- 黑盒套件：`make test-blackbox`（119 项，118 passed + 1 xpassed）。
- 二进制指纹：生产部署的那一份用 `sha256sum` 记录；重新构建（换 Go 版本或改源码）会变。
