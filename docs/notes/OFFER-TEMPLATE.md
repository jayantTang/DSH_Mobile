# 免费中转试用：30 个邀请码（2026-10-17 前有效）

想把 **DSH（DeepSeek Harness）装进手机**的话，可以用我这台中转，不用自己买服务器。
iOS App 走 TestFlight 分发，Android/网页端请看仓库 README。

## 一、手机先装 App（iPhone）

1. 用 **Safari** 打开 → **https://testflight.apple.com/join/tHKQsbCk**
   （微信/QQ 内置浏览器常常打不开，右上角选「在 Safari 中打开」）
2. 点「**接受邀请**」。手机没装 **TestFlight** 的话会先让你去 App Store 装它（Apple 官方 App，免费）
3. 回到 TestFlight，点「**安装**」，DSH Mobile 就出现在桌面了

> ⚠️ **两个要知道的限制**
> - **TestFlight 构建 90 天后过期**：到期那天 App 会提示「此构建已过期」并打不开，
>   需要装我之后发的新构建（我会在这个 issue 里说）。
> - 这个 App 只支持 iPhone，且需要一个邀请码才能连上（见下）。

## 二、电脑上三步

```bash
# 1. 装连接器（npm 上的包）
dsh plugin --profile web add dsh-plugin-mobile-link

# 2. 用邀请码把这台电脑登记到中转（下面的码挑一个没用过的）
dsh-mobile-link enroll --invite <邀请码> --relay RELAY_PLACEHOLDER

# 3. 重启 DSH，然后用手机 App 扫 /mobile-link/qr 的二维码配对
dsh web
```

详细步骤与排错：https://github.com/jayantTang/DSH_Mobile/blob/main/docs/ONBOARDING.md

## 三、规则（都是自动生效的，先说清楚免得意外）

- 每个码**只能用一次**，绑一台电脑；用过的码再填会报 `invite/used`。
- 单设备出口限速 20 Mbps、**每日 2 GB**（UTC 零点重置）。限速只让图慢一点，**不掉帧**。
- 一台电脑最多连 8 台设备。
- 中转**只做鉴权与转发，不解析会话内容**；但流量在这台机器上是**终止 TLS 的**，
  所以别拿它跑你不愿意经过第三方的东西。
- 被滥用我会撤掉对应的电脑（`agent-disable`），撤了之后那台电脑需要重新登记。

## 四、邀请码（用一个少一个，用完我会在下面补新的）

| # | 邀请码 |
|---|---|
> 邀请码用 `admin.py invite-mint --note ... --count N --ttl-seconds ...` 铸出来贴在这里。
> **不要提交进仓库**：码是真凭据，仓库里只留这份模板。

## 五、遇到问题

直接在这个 issue 下面回，把现象、手机型号/iOS 版本、电脑上 `dsh-mobile-link --log-level debug --once`
的输出贴上来即可。中转的实时负载我也在看（谁在用、用了多少流量），所以「连不上」这类问题
我通常能直接看出是中转还是本机的问题。

> 中转资源：2 vCPU / 4 GB / **200 Mbps 固定带宽**（包年，无流量费）。目前就我一个人在用。
