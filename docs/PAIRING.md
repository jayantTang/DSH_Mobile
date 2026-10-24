# 连接与配对设计

> 面向：实现者与部署方 · 状态：stable · 最近核对：2026-10-24

## 决定：只保留一条路

**产品上只提供「经公网中转」这一种连接方式**，不给用户选。

理由：

- 两边本来都要联网才能用上模型，直连省下的那点流量没有意义；文本流本身很小。
- 两套连接方式意味着两套故障模式、两套排查路径、两套能力差异（文件发送就只在
  中转下能用）。支持成本远大于收益。
- 用户在家用 Wi-Fi 时走中转也不担心流量，且体验完全一致。

**保留的例外**：`dsh://direct?...` 仍是 **DEBUG-only** 的启动参数，只供仿真器用例
连接本机 DSH 使用，不出现在任何用户界面里。它是测试通道，不是产品特性。

## 配对的现状

| 组件 | 现状 |
|---|---|
| 中转 `agents` 表 | 存在，且 `agentSecret` **只存哈希** |
| 中转 `accounts` 表 | 已启用：邀请码登记时在同一事务里建账户与电脑，设备、用量与配额按账户归属 |
| 配对码 | 中转 `POST /pair/code` 签发（一次性、默认 10 分钟）；连接器 `/mobile-link/pair-code` 取用，手机 `/pair/claim` 兑换 |
| 二维码 | 连接器 `POST /mobile-link/pair-code` 一次返回码、payload 与图案（`dsh://pair?relay=…&code=…`）；DSH 界面左下角「移动端连接」小窗展示它，App 扫码或手输配对码。取码接口**每次调用都新签一张**，小窗在码被兑换（在线手机台数增长）或剩余不足 1 分钟时自动换，也可手动换（spec 010）。旧的浏览器页面 `GET /mobile-link/qr` 已删除 |
| 设备令牌 | 已签发，按 agent 归属，长期有效并随 `/pair/refresh` 轮换 |
| 设备管理 | 中转 `GET /devices`、`POST /devices/revoke` + `dsh-relay admin device-list`；**App 设置页已可看已配对设备并撤销** |
| 直连入口 | App 连接页**已去掉**，只保留中转配对；`dsh://direct` 仅 DEBUG 参数 |

**登记入口**：连接器用一次性邀请码走 `POST /agents/enroll` 自助领取 `agentId` + `agentSecret`；
运营者仍可用 `dsh-relay admin agent-register` 手工预置或轮换身份。

## 目标形态

```
① 用户在电脑上装 DSH + 本项目插件
        │
② 首次启动，连接器向中转「登记」，拿到 agentId + agentSecret
        │        （需要账号或邀请码，不能完全开放）
        ▼
③ 连接器在 DSH 界面（侧栏底部「移动端连接」）显示一个二维码（含 relayUrl + 一次性配对码）
        │
④ 手机 App 扫码 → POST /pair/claim → 拿到 deviceToken
        │
⑤ 之后自动重连，无需再配对
```

### 为什么是扫码而不是输码

配对码要 8 位、带连字符、还要区分大小写，手输一次成功率很低；而且用户要先把
`wss://…/dsh-link` 这种地址抄到手机上。二维码把「地址 + 码」一次带过去，
这也是桌面版 DSH 已有的交互方式。

### 登记（第 ② 步）怎么防滥用

三个层次，按落地顺序：

1. **邀请码**（最小可用）：中转签发一次性邀请码，连接器用它换身份。
   成本低，足以支撑早期几十个用户。
2. **账号**（`accounts` 表已启用）：邀请码兑换时建账户，身份与用量按账户归属，
   便于做设备列表、撤销与配额。
3. **限流与配额**：限制每 agent 的设备数、单设备速率与每日字节额度。
   邀请码与配对码各有失败预算。

**不允许**完全开放的匿名登记——中转是公网可达的，开放登记等于把服务器交出去。

## 能力清单

| 项 | 说明 | 状态 |
|---|---|---|
| 连接器自助登记 | 用邀请码换 agentId/secret；`dsh-relay admin agent-register` 保留为运营工具 | ✅ 已具备（`POST /agents/enroll`）|
| 二维码 | 连接器出图（`POST /mobile-link/pair-code` 带 `svg`），DSH 界面「移动端连接」小窗展示 | ✅ 已具备（010 起在界面里）|
| 设备自助管理 | App 内可看已配对设备、可撤销 | ✅ 已具备 |
| App 去掉直连入口 | 连接页只保留「中转配对」 | ✅ 已具备 |
| 能力探测 | 连接器 `status` 回报 `capabilities`，App 据此显示/隐藏功能 | ✅ 已具备 |
| 配额与限流 | 每 agent 设备数、单设备速率与每日字节额度；邀请码与配对码各有失败预算 | ✅ 已具备 |

## 兼容性备忘

连接器 `status` 现已回报：

```json
{ "serverVersion": "0.2.0",
  "capabilities": ["file-transfer", "events", "session-streams",
                   "pair-code", "qr-pairing", "self-enroll"] }
```

（实际清单来自 `plugins/mobile-link/lib/hello.js` 的 `SERVER_CAPABILITIES`；
`serverVersion` 读的是插件 `package.json`，不是手写常量。）

App **必须做能力探测而非版本比较**：老连接器缺某个能力时，对应入口隐藏并说明，
而不是让调用打到 Host 上得到 404。这一条已经踩过——文件功能在旧连接器下只报
「DSH returned HTTP 404」，看不出真正原因。

## 安全待办

- `agentSecret` / `deviceToken` 已只存哈希（已具备）
- 已定：配对码一次性、默认 10 分钟；失败原因在协议上分成 `pair/invalid-code` /
  `pair/used-code` / `pair/expired-code`，限流见 `_CLAIM_FAILURES`
- 待确认：设备撤销后的令牌失效传播
- 待确认：中转上的会话数据是否落盘（当前为纯转发，应保持不落盘）
