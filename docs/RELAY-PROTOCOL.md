# DSH Link Protocol (DLP) v1

规范版本：`1`
状态：draft-1（已按本规范实现 relay / agent / iOS 客户端）

DLP 解决的核心问题：**电脑端 DSH 没有公网 IP**。电脑侧连接器（agent）主动外连中转服务器，
手机（device）也连中转服务器，由中转按 `agentId` 配对并转发帧。

设计目标：

1. **不重新定义 DSH 语义**。DLP 只是 DSH 原生协议（HTTP `/api/<method>` + WS `/api/remote.mux`）
   的**多路复用隧道**。转发层不认识 session、不解析事件，因此 DSH 升级不会破坏 DLP。
2. **单连接多路复用**。手机与电脑之间只有一条 WSS，承载全部一元 RPC、全部逻辑流、以及宿主事件。
3. **多设备 / 多用户可扩展**。同一 agent 可被多台设备连接；中转按账号隔离，为后续上架预留。

---

## 1. 拓扑

```
 iOS App (device)                Relay (公网)                 PC (agent)
      │                              │                            │
      │  WSS /link/device            │       WSS /link/agent      │
      ├─────────────────────────────►│◄───────────────────────────┤
      │  Bearer <deviceToken>        │      Bearer <agentToken>   │
      │                              │                            │
      │                              │                     ┌──────┴───────┐
      │                              │                     │ dsh web      │
      │                              │                     │ 127.0.0.1:P  │
      │                              │                     └──────────────┘
```

Relay 只做两件事：**鉴权**与**按 `agentId` 转发**。它不解析 DLP 之外的任何 DSH 语义。

---

## 2. 端点

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET`  | `/healthz` | 健康检查，返回 `{"ok":true,"version":1}` |
| `WS`   | `/link/agent?agentId=<id>` | 电脑侧连接器接入；`Authorization: Bearer <agentToken>` |
| `WS`   | `/link/device?agentId=<id>` | 手机侧接入；`Authorization: Bearer <deviceToken>` |
| `POST` | `/pair/claim` | 手机用配对码换取 `deviceToken` |
| `POST` | `/pair/refresh` | 刷新 `deviceToken`（长期使用） |
| `OPTIONS` | `*` | CORS 预检 |

`agentId` 也允许放在首帧 `hello` 中；query 参数优先。

### 2.1 `/pair/claim`

请求：

```json
{ "pairCode": "7F3K-9Q2M", "deviceName": "Example iPhone", "deviceModel": "iPhone17,1", "appVersion": "1.0.0" }
```

响应 `200`：

```json
{ "ok": true, "agentId": "agt_...", "deviceToken": "dt_...", "accountId": "acc_...",
  "agentName": "Example 的 MacBook Pro", "expiresAt": 1790000000000 }
```

失败：`{"ok":false,"error":{"code":"pair/invalid-code","message":"..."}}`

- 配对码一次性、有时效（默认 10 分钟），由电脑侧连接器生成并展示（二维码 / 终端）。
- `deviceToken` 长期有效（默认 365 天），并随 `/pair/refresh` 轮换。

### 2.2 鉴权失败

WS 升级阶段失败直接回 HTTP `401` / `403`（不进入 WS 状态机）。
进入 WS 后鉴权失败回 `{"t":"error","code":"auth/...","fatal":true}` 并关闭。

---

## 3. 帧格式

- 传输：WebSocket **文本帧**，UTF-8 JSON 对象。
- 每条帧必须有 `t`（string）。
- 未知 `t` **必须忽略**（前向兼容）。
- 二进制帧保留给附件传输（v2）。

### 3.1 device → agent

| `t` | 字段 | 语义 |
|---|---|---|
| `req` | `id`, `method`, `args` | 一元 RPC。`method` 为 DSH 端点名（如 `session/list`），`args` 为 DSH 命名字段对象 |
| `open` | `id`, `endpoint`, `args` | 打开逻辑流（如 `session/follow`、`$events`） |
| `cancel` | `id` | 取消逻辑流 |
| `eventResult` | `id`, `result` | 回应宿主 `$events/result`（waterfall 应答） |
| `ping` | `ts` | 心跳，agent 回 `pong` |

### 3.2 agent → device

| `t` | 字段 | 语义 |
|---|---|---|
| `res` | `id`, `ok`, `value`? / `error`? | 一元 RPC 响应 |
| `item` | `id`, `value` | 逻辑流数据项 |
| `end` | `id` | 逻辑流正常结束 |
| `streamError` | `id`, `error` | 逻辑流失败 |
| `event` | `value` | 宿主事件（来自 `$events` 流） |
| `hostStatus` | `info` | agent/DSH 状态变化（上线、离线、版本、工作区） |
| `pong` | `ts` | 心跳回应 |
| `error` | `code`, `message`, `fatal`? | 协议级错误 |

`id` 为 device 生成的字符串，唯一标识一次 RPC 或一条逻辑流。agent 必须原样回填。

`error` 对象统一为 `{"code":string,"message":string,"details":object}`，与 DSH 的失败形状一致。

### 3.3 示例

手机列出会话：

```json
{"t":"req","id":"1","method":"session/list","args":{"_request":{}}}
```
```json
{"t":"res","id":"1","ok":true,"value":{"items":[...]}}
```

手机订阅某会话实时事件：

```json
{"t":"open","id":"2","endpoint":"session/follow","args":{"request":{"agentId":"session-...","afterSeq":3883}}}
```
```json
{"t":"item","id":"2","value":{"type":"event","event":{...}}}
{"t":"item","id":"2","value":{"type":"assistant-stream","frame":{...}}}
```

手机回答宿主的交互提问：

```json
{"t":"eventResult","id":"3","result":{"clientId":"ae3f...","eventId":"5e51...","outcome":{"kind":"result","value":{"answers":[...]}}}}
```

---

## 4. agent 行为规范

### 4.1 与本地 DSH 的对接

1. **发现端点**：读取 `$DSH_HOME/desktop-shell/endpoint.json` 的 `url`/`port`；
   若不可用则回退 `$DSH_WEB_URL`、再回退 `http://127.0.0.1:54499`。
   端点可能因 DSH 重启而变化，**每次重连都要重读**。
2. **认证换取**：`GET <base>/?token=<token>`，**不要跟随重定向**，从 `Set-Cookie` 取
   `dsh-auth-*`，后续所有请求带该 Cookie。token 失效（401）时重读 endpoint.json 并重试一次。
   - 注意：DSH 的认证 Cookie **绑定 authority（host:port）**，因此 agent 必须始终以
     `127.0.0.1:<port>` 这个 authority 访问，不得改写 Host。
3. **一元 RPC**：`POST <base>/api/<method>`，
   body `{"type":"client-request","rpcId":"<id>","method":"<method>","payload":{"args":<args>}}`，
   响应 `{"type":"server-response","rpcId":"<id>","result":{"ok":true,"value":...}|{"ok":false,"error":{...}}}`。
   agent 把 `result` 直接映射为 DLP 的 `res`。
4. **逻辑流**：agent 维护**一条**到 `<ws-base>/api/remote.mux` 的 WebSocket，承载所有设备的
   所有逻辑流。device 的 `id` ↔ mux `streamId` 一一映射。
   - 打开：`{"type":"open","streamId":"<muxId>","endpoint":"<endpoint>","payload":{"args":<args>}}`
   - 上行收到 `item`/`error`/`end` 后转成对应 DLP 帧。
   - 设备 `cancel` → 发 `{"type":"cancel","streamId":"<muxId>"}`。
5. **宿主事件**：agent 在 mux 上额外打开 `$events`（`{"args":{}}`），把每条 `item` 以
   `{"t":"event","value":<item>}` 广播给**所有已连接设备**。
   其中 `ready` 帧携带 `clientId`，**每个 device 需要自己的 clientId**：
   `$events/result` 的 `clientId` 必须与开启该流时收到的 `ready.clientId` 一致。
   → 因此 agent 为**每个 device** 单独打开一条 `$events` 流。
6. **waterfall 去重**：同一个 `eventId` 的 waterfall 会推给多台设备。**首答生效**，
   其余丢弃（agent 按 `eventId` 记录已答集合，TTL 清理）。

### 4.2 可靠性

- 心跳：device 每 20s 发 `ping`；agent 每 20s 也主动 `ping` relay。`pong` 超时 60s 判定断线。
- 重连：指数退避 `1s → 2s → 4s ... 上限 30s`，加 ±20% 抖动。
- device 断开时，agent 必须 `cancel` 该 device 拥有的全部逻辑流，避免泄漏。
- agent 重启后 `agentId`/`agentToken` 保持不变（持久化到 `$DSH_HOME/mobile-link/agent.json`）。

---

## 5. relay 行为规范

- 维护 `agentId → agentConnection` 注册表；同一 `agentId` 重复接入时**新连接顶掉旧连接**。
- device 连上时若 agent 不在线，回 `{"t":"hostStatus","info":{"online":false}}`，
  并在 agent 上线时补发 `{"t":"hostStatus","info":{"online":true,...}}`。device 无需轮询。
- 转发时**保留原帧**，不改写 `id`。
- 帧大小上限 32 MiB（对齐 DSH 的图片附件上限）。
- 单 device 未确认帧上限（背压）512 条，超限断开防止内存膨胀。
- device 断开：通知 agent 清理该 device 的流。

---

## 6. 局域网直连（优先路径）

DLP 不是唯一路径。手机与电脑同一局域网时，**优先直连**，性能最好、不消耗服务器流量：

- 电脑侧 `dsh web --host 0.0.0.0` 监听局域网。
- 手机直接 `http://<mac-lan-ip>:<port>` 走原生 HTTP + WS；DSH 的 trust fence 自动接受
  局域网 IP 字面量，无需额外配置。
- 认证仍用 `?token=` 换取 Cookie；手机需要拿到 token（agent 通过中转把 token 下发给已配对设备，
  或用户在电脑端扫码）。
- iOS 客户端 `DSHTransport` 抽象使两种路径对上层完全一致。

---

## 7. 中转侧 DSH 配置

> **本节的前提不成立，实现未采用。** 见 `notes/relay.md` §1。

本节假设 DSH 看到的 `Host` 是中转域名。实际上 agent 直接连
`127.0.0.1:<port>`，并且**不改写 `Host`**（§4.1.2 也要求如此，认证 Cookie 绑定
authority），所以 trust fence 看到的是回环地址、直接放行：

```
dsh web          # 不需要 --trusted-host
```

agent 改为在启动时校验真正要紧的三件事：重读 `endpoint.json`、完成
token → cookie 交换、失败时把原始错误写进 `GET /mobile-link/status` 的 `dsh.error`
与日志。若通过 `dshUrl` 显式指定了非回环地址，则按指定值处理。
