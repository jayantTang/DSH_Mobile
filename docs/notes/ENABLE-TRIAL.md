# 让「别人能试」的两条路

宣传的流量最后都撞在同一件事上：**别人 clone 下来连不上任何中转，而 iOS 也没法一条命令
装**。这份文件把两条路各写到「只剩你点一下」的程度。

- [一、公共中转（现在的形态：邀请码 + 现有 relay）](#一公共中转)
- [二、TestFlight（现状、缺什么、怎么做）](#二testflight)
- [三、别做的事](#三别做的事)

---

## 一、公共中转

现有的 relay 已经在跑（就是我们自己那台，地址见 `.env.local` 的 `DSH_SITE`；我从本机上去看过：
Caddy 与 dsh-relay 两个服务都是 active，2 vCPU / 3.5 GB 内存 / 磁盘用掉 15%），所以这条路
**今天就能开**：把邀请码发给别人，他们用自己的电脑连上中转，配合同一份 App 构建即可。

### 开通（在服务器上，我也可以代跑）

```bash
# 1. 铸邀请码（有效期默认 7 天，一次可多铸几个）
HOST=${DSH_OTA_HOST#*@}; HOST=${HOST%%/*}          # 或者直接把主机名写在这里
ssh "root@$HOST" 'cd /opt/dsh-relay && \
  .venv/bin/python admin.py --db /var/lib/dsh-relay/state.db \
  invite-mint --note "公开试用 2026-09" --count 10'

# 2. 把打印出来的那行发给对方，他在自己电脑上跑
dsh-mobile-link enroll --invite <码> --relay wss://<你的站点>/dsh-link
```

`enroll` 之后连接器会把自己的身份写进 `~/.dsh/mobile-link/agent.json`，此后随 DSH 启动。
之后他打开 `/mobile-link/qr` 用手机扫码，就完成配对了。**他不需要有自己的服务器。**

### 这套东西现在的承载能力（已核实，不是估计）

| 项 | 现状 | 含义 |
| --- | --- | --- |
| 中转协议 | 文本帧 JSON 转发，**无压缩** | 单核约 37 万小帧/秒（本机实测）；瓶颈是流量费不是 CPU |
| 单帧上限 | 32 MB | DSH 的图片附件上限对齐，一张图不会撑爆 |
| 设备背压 | 每设备 512 帧队列，溢出即断该设备（4008） | 慢设备只影响自己，不会把中转内存吃穿 |
| 连接器背压 | 4096 帧 | 连接器掉线时给设备留了缓冲 |
| 实例带宽 | **200 Mbps 固定带宽、年费固定**（2026-09-17 从控制台确认） | 没有流量费；1000 个活跃用户每天约 19.5 GB，占全天容量的 0.93% |
| **单设备出口限速** | **20 Mbps** | 手机上感觉不到限速；10 台设备同时传大图才刚好占满管子。限速只让设备变慢，**不掉帧** |
| **单设备每日额度** | **2 GB / UTC 天** | 这才是防「把中转当代理」的那道：重度用户一天 100–300 MB，2 GB 留了约 10 倍余量；拿去当代理十几分钟就用完。超额先收到 `quota/device-daily` 的 error 帧，再以 4011 断开，次日恢复 |
| **每 agent 设备数** | **8 台** | 挡住泄漏的 deviceToken 或配对脚本把中转塞满；同一设备重连不占第二个名额 |
| 配对防爆破 | 失败计数 + 429 | 短码不会被离线穷举 |
| 中转能看到什么 | agentId / deviceId / 帧类型；**不解析会话内容** | 但**流量是明文 TLS 终止在中转上**——邀请别人之前这句话要讲清楚 |

> 三个限额的取值口径写在 `relay/deploy/dsh-relay.service` 的注释里，已按 200 Mbps 复核。
> 换到更小的管子（例如 5 Mbps 的按量实例）时，把限速调到 2–5 Mbps：限速的口径是
> 「管子 ÷ 预期同时传大文件的设备数」，不是「管子 ÷ 设备数」。改完在服务器上
> `systemctl daemon-reload && systemctl restart dsh-relay`。

### 看实时流量（在你自己的电脑上跑，不用登服务器）

```bash
HOST=${DSH_OTA_HOST#*@}; HOST=${HOST%%/*}
ssh "root@$HOST" 'curl -s http://127.0.0.1:8787/stats' | python3 -c "
import json,sys
d = json.load(sys.stdin)
print('agent', d['load']['agents'], '| 设备', d['load']['devices'],
      '| 本次启动累计出口 %.2f MB' % (d['traffic']['totalEgressBytes']/1048576))
for x in d['traffic']['devices']:
    print('  %-10s %-24s %8.2f MB  限速等待 %5.1fs  今日剩余 %s' % (
        x['name'] or '—', x['deviceId'], x['egressBytes']/1048576, x['pacedSeconds'],
        '不限' if x['quotaRemainingBytes'] < 0 else '%.0f MB' % (x['quotaRemainingBytes']/1048576)))
"
```

`/stats` 只监听回环，所以必须走 SSH（也可以把 8787 转发出来用浏览器打开，会渲染成每 5 秒
自刷新的页面）。它回答的是「哪台设备在用带宽」——主机的网卡计数器回答不了这个问题，
因为那里混着 SSH 与 OTA 下载。

### 你要先做的两个决定

1. **发给谁**：邀请码 = 允许对方的电脑连上你的中转。中转不碰会话内容，但它承载全部流量，
   而流量费是你的。建议第一批 5–10 个，只发给会真的用的人。
2. **限额**：现在没有按账号的流量/连接限额。真要公开，先加两道——
   每 agent 的连接数上限、每设备每天的中转字节数上限（`Limits` 里加字段即可）。
   **没加之前不要把邀请码发到公开帖子下。**

---

## 二、TestFlight

### 现状（I checked，不是猜的）

| 项 | 状态 |
| --- | --- |
| 本机代码签名身份 | 只有 `Apple Development: jingyang Tang (M6ML33FNV3)` —— **没有 Apple Distribution** |
| 已安装的描述文件 | 0 个（`~/Library/MobileDevice/Provisioning Profiles` 是空的；OTA 用的那份是 Xcode 自动管理的） |
| 现在的分发方式 | OTA：`ExportOptions-ota.plist` 的 `method = debugging`，即 Apple Development 证书 + 团队描述文件。只覆盖**已登记 UDID 的设备**（手机已登记，有效期到 2027-02-11） |
| Xcode | 26.2（本机），可用 |
| 上传通道 | 有 `altool`/`notarytool` 一类工具，但**都需要 App Store Connect 的账号与专用密码** |

### 缺的三样（都只能你来）

1. **Apple Developer Program 会员**（$99/年）。个人免费账号做不了 TestFlight。
2. **Apple Distribution 证书 + App Store 描述文件**。有了会员之后，Xcode →
   Settings → Accounts 登录，然后在 Signing & Capabilities 勾上
   「Automatically manage signing」，Xcode 会自己生成这两样。
3. **App Store Connect 里的 App 记录**（bundle id `com.jayanttang.dsh`）与一次上传。
   另外 TestFlight 的构建必须**递增 build number**，现在 `manageAppVersionAndBuildNumber`
   是 `false`，也就是说版本号要你自己抬。

### 会员到位之后的做法（我可以代跑）

```bash
cd ios/DSHMobile
xcodebuild -scheme DSHMobile -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath .build/DSHMobile.xcarchive archive
# TestFlight 用 app-store 这一档（与 OTA 的 debugging 不同）
xcodebuild -exportArchive -archivePath .build/DSHMobile.xcarchive \
  -exportOptionsPlist <app-store 版的 plist> \
  -exportPath .build/testflight
xcrun altool --upload-app -f .build/testflight/DSHMobile.ipa \
  -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
```

需要新增一个 `ExportOptions-appstore.plist`（`method = app-store-connect`）——**这件我可以现在
就写好**，等证书一到就能直接跑。再配一个 `scripts/release/deploy-testflight.sh`，把上面三步
包起来，跟 `deploy-ota.sh` 并列。

### 还差一个产品决定

TestFlight 分发的 App 默认**连的是构建时注入的中转地址**（`Config.local.xcconfig` 里那个）。
给别人测试 = 他们连你的中转。所以第二节和第一节是同一件事：**先把中转的限额做了，
再发 TestFlight**。

---

## 三、别做的事

- **别把邀请码直接贴到公开帖子下面**再补限额。中转一被刷，受影响的是你所有真实会话的可用性。
- **别用免费 Apple ID 硬凑 TestFlight**。免费账号的签名 7 天过期，测试者装一次骂一次，
  比不给安装包更伤。
- **别为了让别人能试而把 App 改成「填任意中转地址就能连」**。现在的形态是「你给别人邀请码」，
  这跟「你给别人你的电脑访问权」是同一件事；反过来不成立。要想清楚再放开。
