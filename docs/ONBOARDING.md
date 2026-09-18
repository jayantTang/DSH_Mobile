# 装完之后怎么用

一页讲完「两条路怎么选」和「对不上怎么查」。第一次用的人看这个，回答 issue 的人也从这里引用。

---

## 两条路，先选一条

| | **A · 用现成中转**（推荐） | **B · 自己开中转** |
|---|---|---|
| 适合谁 | 只想赶紧用起来 | 想要完全自主、不依赖别人的机器 |
| 前提 | 一个邀请码（一次性，绑一台电脑） | 一台有公网 IP 的主机（能装 Caddy） |
| 耗时 | 约 5 分钟 | 约 20 分钟 |
| 你要做什么 | 装连接器 → 填邀请码 → 扫码 | 部署中转 → 铸码 → 同上 |

**两条路在第 4 步之后完全一样**：手机扫码配对、之后自动重连。

---

## 你要先有三个东西

| 东西 | 从哪来 | 没有会怎样 |
|---|---|---|
| 跑着 DSH 的电脑 | `npx @deepseek-ai/dsh web` | 手机连上了也没会话可看 |
| 电脑上的连接器 | `dsh plugin --profile web add dsh-plugin-mobile-link` | 手机扫不出配对码，或连上就断 |
| 手机上的 App | TestFlight 公开链接（见仓库 README） | — |

中转不是第四个东西：A 用别人的，B 自己开。区别只是「谁是那台公网机器」。

---

## A · 用现成中转（5 分钟）

### 第 1 步：手机装 App

Safari（不要用微信内置浏览器）打开邀请页 → **接受邀请** → 若没装 TestFlight 会先跳去 App Store
装它 → 回到 TestFlight 点 **安装**。

> TestFlight 构建 **90 天后过期**，到期那天 App 会提示并打不开，需要装新构建（仓库 issue 里会说）。

### 第 2 步：电脑装连接器

```bash
dsh plugin --profile web add dsh-plugin-mobile-link
```

### 第 3 步：用邀请码把这台电脑登记到中转

邀请码与中转地址一起给你，形如：

```bash
dsh-mobile-link enroll --invite ABCD-EFGH-JKLM-NPQR --relay wss://<中转地址>/dsh-link
```

成功后身份写在 `~/.dsh/mobile-link/agent.json`，**这台电脑以后不用再登记**。
（也可以用环境变量代替参数：`DSH_MOBILE_LINK_INVITE=<码> dsh web`，适合写进服务配置。）

### 第 4 步：重启 DSH

连接器是跑在 DSH 进程里的插件，**不重启等于没装**：

```bash
ps -eo pid,lstart,command | grep 'bin/dsh web' | grep -v grep   # 看现在的进程
# 退出 DSH 后重新启动
dsh web
```

### 第 5 步：扫码配对

电脑上打开二维码：DSH 界面里的「移动端连接」，或浏览器访问
`http://127.0.0.1:<dsh 端口>/mobile-link/qr`（端口见 `~/.dsh/desktop-shell/endpoint.json`；
这个页面要 DSH 的登录态，所以用本机浏览器打开，别用手机）。

手机 App → 底部 **扫码配对** → 扫它。也可以把二维码里的配对码手输进「配对码」框。

### 第 6 步：确认连上了

```bash
curl -s "http://127.0.0.1:<dsh 端口>/mobile-link/status"   # 浏览器打开更省事（要登录态）
```

`"connected": true` + `deviceCount ≥ 1` 就说明两端对上了。

---

## B · 自己开中转（20 分钟）

```bash
# 在服务器上（需要 root 与已装好的 Caddy）
ssh <你的服务器>
cd relay && export DSH_RELAY_SITE=<你的站点>
sudo -E ./deploy/deploy.sh                 # 幂等：建用户、装 systemd 单元、插 Caddy 路由

# 建账号 → 给自己铸一个邀请码
python3 admin.py --db state.db account-create --name "<你>"
python3 admin.py --db state.db invite-mint --note "给自己" --count 1 \
    --relay wss://<你的站点>/dsh-link
```

拿到码之后**回到 A 的第 2 步**继续（装连接器 → enroll → 重启 → 扫码）。

`deploy.sh` 不新增 DNS 与证书：它把一段带标记的路由片段插进既有站点块，写入前先
`caddy validate`，失败即回滚；`--uninstall` 按标记原样移除。

运维侧的实时负载、每设备流量与生效中的限额：

```bash
curl -s http://127.0.0.1:8787/stats | python3 -m json.tool | head -40
```

自建时建议开限额（固定带宽共享时防止一个人拖慢所有人）：
`DLP_DEVICE_RATE_KBPS` / `DLP_DEVICE_DAILY_MB` / `DLP_MAX_DEVICES_PER_AGENT`，
取值口径写在 `relay/deploy/dsh-relay.service` 的注释里。

---

## 配对之后能用什么

两端看到的是**同一个 DSH**：同一批会话、同一条消息流。

| 能力 | 手机侧 | 电脑侧需要 |
|---|---|---|
| 看会话列表、读转写、看工具调用 | ✅ | DSH 在跑 |
| 发消息、打断正在跑的任务 | ✅ | 同上 |
| 回答 agent 的提问卡片 | ✅ | 同上 |
| 发图片进会话（相册/文件） | ✅ | 连接器已登记 |
| 上传文件到会话工作区 | ✅ | 落在 `~/.dsh/inbox/<sessionId>/` |
| 看图、代码高亮、HTML 报告预览 | ✅ | — |
| 锁屏后任务继续跑 | ✅ | 电脑不睡眠 |
| 电脑端**新开**的会话叫醒手机 | ❌ | 需要 APNs，尚未实现 |

权限（只读 / 仅工作区可写 / 完全访问）在电脑上的 DSH 设置里，手机侧只显示当前档位。

---

## 连不上怎么查（按顺序）

| 现象 | 先看这里 | 常见原因 |
|---|---|---|
| 二维码页打不开 / 404 | DSH 是否重启过 | 插件没生效：`ps` 看 DSH 进程的启动时间 |
| App 显示「电脑离线」 | 电脑侧 `/mobile-link/status` 的 `enroll.registered` | 没登记：回到 A 第 3 步 |
| 状态里 `state: backoff` + `4001 superseded` | 是不是有**第二个** DSH 在跑同一个身份 | 旧进程没退干净，`kill` 掉旧的 |
| 连上但会话列表空 | 电脑上 DSH 里有没有会话 | — |
| 手机一直「连接中」 | `agent.json` 里的 `relayUrl` 与服务端地址 | 登记时填错了中转地址 |
| 邀请码报 `invite/used` | — | 一个码只能用一次，领新的 |
| 手机端功能缺失 | 发布页有没有新版本 | TestFlight 构建过期 |

要在**不打扰**正在运行的连接器的前提下确认它能不能连上：

```bash
dsh-mobile-link --log-level debug --once      # 打印一行 MOBILE_LINK_STATE 就退出
```

`connected: true` 就是通的。**别长时间前台跑**：连接器的身份是唯一的，第二个连上会把 DSH 里
那个顶掉（日志里的 `4001 superseded`），DSH 里那个随后会自己重连。

---

## 卸载 / 换中转

```bash
# 换中转：撤掉旧身份，再重新登记
rm ~/.dsh/mobile-link/agent.json
dsh-mobile-link enroll --invite <新邀请码> --relay wss://<新站点>/dsh-link

# 卸载连接器
dsh plugin --profile web remove dsh-plugin-mobile-link
```

手机侧在「设置 → 已配对的设备」里可以撤销某台设备；撤销后那台手机需要重新配对。
