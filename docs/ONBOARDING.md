# 装完之后怎么用

一页写完「两端怎么对上」和「对不上怎么查」。给第一次用的人看，也给回答 issue 的人看。

---

## 一、你要先有三个东西

| 东西 | 从哪来 | 没有会怎样 |
|---|---|---|
| 跑着 DSH 的电脑 | `npx @deepseek-ai/dsh web` | 手机连上了也没会话可看 |
| 电脑上的连接器 | `dsh plugin --profile web add dsh-plugin-mobile-link` | 手机扫不出配对码，或连上就断 |
| 手机上的 App | 发布页 OTA 安装 / TestFlight / 自己用 Xcode 构建 | — |

**中转不是第四个东西**：可以用别人的（拿邀请码登记即可），也可以自己开一台
（`relay/deploy/deploy.sh`）。区别只是「谁是那台公网机器」。

---

## 二、五步跑通

### 第 1 步：电脑上装连接器

```bash
dsh plugin --profile web add dsh-plugin-mobile-link
```

装完**必须重启 DSH**——连接器是跑在 DSH 进程里的插件，不重启等于没装：

```bash
# 先看现在的 DSH 进程
ps -eo pid,lstart,command | grep 'bin/dsh web' | grep -v grep
# 退出 DSH 再重新启动
dsh web
```

### 第 2 步：让这台电脑在中转上登记

两种情形，看你有哪种：

**A. 用别人的中转（有邀请码）**

```bash
dsh-mobile-link enroll --invite <邀请码> --relay wss://<对方站点>/dsh-link
```

邀请码是一次性的。登记成功后身份写在 `~/.dsh/mobile-link/agent.json`，**这台电脑之后
不用再登记**。也可以用环境变量代替参数（适合写进服务配置）：

```bash
DSH_MOBILE_LINK_INVITE=<邀请码> dsh web    # 首次启动时自动登记
```

**B. 自己开中转**

```bash
ssh <你的服务器>
cd relay && export DSH_RELAY_SITE=<你的站点>
sudo -E ./deploy/deploy.sh
python3 admin.py --db state.db account-create --name "<你>"
python3 admin.py --db state.db invite-mint --note "给自己" --count 1
python3 admin.py --db state.db agent-register --account <acc_x> --name "<机器名>" \
    --write-config ~/.dsh/mobile-link/agent.json --relay wss://<你的站点>/dsh-link
```

### 第 3 步：生成配对码 / 二维码

重启 DSH 后，两种拿法：

- DSH 界面里打开「**移动端连接**」（会渲染二维码）；
- 或浏览器打开 `http://127.0.0.1:<dsh 端口>/mobile-link/qr`
  （端口在 `~/.dsh/desktop-shell/endpoint.json` 里；这个页面要 DSH 的登录态，
  所以用本机浏览器打开，别用手机浏览器）。

配对码默认 10 分钟有效。命令行也能生成，给自动化用：

```bash
dsh-mobile-link --mint-pair-code     # 打印 JSON：code + relay + agentId
```

### 第 4 步：手机扫码

App 首次启动 → 扫码（或手输配对码）→ 连上后进入会话列表。

配对链接长这样，也可以直接发给手机（AirDrop / 备忘录）：

```
dsh://pair?relay=https://<站点>/dsh-link&code=ABCD-1234
```

### 第 5 步：确认两端都对上了

电脑侧读连接器状态（浏览器打开最省事，命令行要带 DSH 的登录 cookie）：

```bash
curl -s "http://127.0.0.1:<dsh 端口>/mobile-link/status"
```

看到这些就是对的：

```json
{ "connected": true, "state": "connected",
  "enroll": { "registered": true }, "agentId": "agt_…" }
```

---

## 三、配对之后能用什么

两端看到的是**同一个 DSH**：同一批会话、同一条消息流。具体能力：

| 能力 | 手机侧 | 电脑侧需要 |
|---|---|---|
| 看会话列表、读转写、看工具调用 | ✅ | DSH 在跑 |
| 发消息、打断正在跑的任务 | ✅ | 同上 |
| 回答 agent 的提问卡片 | ✅ | 同上 |
| 发图片进会话（相册/文件） | ✅ | 连接器已登记（走中转） |
| 上传文件到会话工作区 | ✅ | 同上；落在 `~/.dsh/inbox/<sessionId>/` |
| 看图、看代码高亮、看 HTML 报告 | ✅ | 同上 |
| 锁屏后任务继续跑 | ✅ | 电脑不睡眠 |
| 电脑端**新开**的会话叫醒手机 | ❌ | 需要 APNs，尚未实现 |

权限（只读 / 仅工作区可写 / 完全访问）在电脑上的 DSH 设置里，手机侧只显示当前档位。

---

## 四、连不上怎么查（按这个顺序）

| 现象 | 先看这里 | 常见原因 |
|---|---|---|
| 二维码页打不开 / 404 | DSH 是否重启过 | 插件没生效：`ps` 看 DSH 进程的启动时间 |
| App 显示「电脑离线」 | 电脑侧 `/mobile-link/status` 的 `enroll.registered` | 没登记：跑第 2 步 |
| 状态里 `state: backoff` + `4001 superseded` | 是不是有**第二个** DSH 在跑同一个身份 | 旧进程没退干净，`kill` 掉旧的 |
| 连上但会话列表空 | 电脑上 DSH 里有没有会话 | — |
| 手机一直「连接中」 | 中转地址对不对 | `agent.json` 里的 `relayUrl` 与服务端实际地址不一致 |
| 手机端 App 是旧的、功能缺失 | 发布页有没有新版本 | OTA 描述文件过期 |

连接器的日志在 DSH 进程里。要在**不打扰**正在运行的那个连接器的前提下确认它能不能连上，
可以前台跑一次「只连一次就退出」：

```bash
dsh-mobile-link --log-level debug --once
```

它会打印一行 `MOBILE_LINK_STATE {...}`，`connected: true` 就是通的。
**别长时间前台跑**：连接器的身份是唯一的，第二次连上会把 DSH 里那个顶掉（日志里的
`4001 superseded by a new agent connection` 就是这个意思），DSH 里那个随后会自己重连。

---

## 五、卸载 / 换中转

```bash
# 换中转：先撤掉旧身份，再重新登记
dsh plugin --profile web remove dsh-plugin-mobile-link     # 或从 profile 里去掉那一行
rm ~/.dsh/mobile-link/agent.json
dsh-mobile-link enroll --invite <新邀请码> --relay wss://<新站点>/dsh-link
```

手机侧在「设置 → 已配对的设备」里可以撤销某一台设备；撤销后那台手机需要重新配对。
