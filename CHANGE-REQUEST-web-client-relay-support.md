# 变更请求：让浏览器客户端能直连既有中转（最小支持改动）

**提出方**：DSH Web 端项目（同机部署的 Web 客户端，浏览器直连中转）
**目标仓库**：本仓库（19_dsh_iosapp）
**提出日期**：2026-10-15
**最后更新**：2026-10-17（第 2 轮：线上真实浏览器取证带回的缺口，新增 FR-009 / FR-010）
**状态**：第一轮改动已上线并验证（子协议鉴权、预检允许 PUT、能力标志、`/devices` 回带 `deviceId`）。
**本轮发现一处未覆盖的缺口**：`GET /files/down` 的流式响应没有 CORS 头，浏览器拿到的是
`blocked by CORS policy`，文件下载在 Web 端完全不可用（见 FR-009）。本文件已把该缺口与
另一处口径不一致（FR-010）补成可验收的需求；本仓库已完成，见 §10。

**这份文件的作用**：本仓库的实现方与验证方**只看这份文件**即可完成开发与验证，不需要回问提出方。
文件包含：为什么改、改哪几处、精确到函数的实现指引、必须补的测试、真实浏览器取证方式、
验收判据、边界承诺、风险与回滚。

**本仓库处理结论（2026-10-17）**：FR-009 已实现，§6.1 第 7 条与 §6.2 第 3 步的取证均已取得；
FR-010 **采纳**（`/healthz` 增加 `file-transfer`）。详细回复与一处取证口径修正见 §10。

**本轮（第 2 轮）只需处理两件事**，其余（FR-001 ~ FR-008）已上线且经线上验证：

| 项 | 是什么 | 改动量 | 是否必做 |
| --- | --- | --- | --- |
| **FR-009** | `GET /files/down` 的 200/206 响应自带 CORS 头（浏览器现在**下不了文件**） | 一行 `response.headers.update(...)`，加在 `prepare()` 之前 | **必做** |
| FR-010 | `/healthz` 的 `capabilities` 增加 `file-transfer`，与 `relay-contract.json` 对齐 | 一个字符串 | 可选（拒绝请书面回复） |

FR-009 的两条验证不能省：§6.1 第 7 条（快闸断言正文响应头）与 §6.2 第 3 步（真实浏览器三步：
整份 / 续传 / If-Range 过期）。上一轮的漏洞正是"只测了预检、没测正文"。

**边界（承诺）**：只做"让浏览器能直连既有中转"所需的最小改动。不改帧格式、不改数据库结构、
不新增端点、不改连接器与 iOS 端、不改限流与额度口径。

---

## 1. 背景：三条硬事实

Web 端的目标是**由用户浏览器直接连接本仓库的中转**（不设中间层），当作一台与 iOS App 并列的
设备接入同一台 DSH host。但浏览器有三条限制：

1. **浏览器无法在 WebSocket 握手时设置自定义请求头**（`new WebSocket()` 不支持自定义头），
   而本仓库中转的设备接入只认 `Authorization: Bearer` 头（`relay/api.py` 的 `bearer_token`）。
   iOS 能做到是因为 `URLSession` 允许设头（`ios/DSHMobile/DSHKit/Sources/DSHKit/LinkCarrier.swift`
   在升级请求上设 `Authorization`）。
2. **既有 CORS 允许的方法不含 `PUT`**（`relay/api.py` 的 `CORS_HEADERS` 为
   `"GET, POST, OPTIONS"`），而手机上传文件走的是 `PUT /files/up`。浏览器发起该请求必先做预检，
   预检答案里没有 `PUT` 就会被拦下。

3. **CORS 校验发生在每一个跨域响应上，预检只是其中一步**。预检（`OPTIONS`）回答"能不能发"，
   正文响应还必须自己带 `access-control-allow-origin`（以及需要给脚本读的头要列进
   `access-control-expose-headers`），否则浏览器把**已经收到的字节**判为不可读并报
   `blocked by CORS policy`。第一轮只把 CORS 当成"预检答案"处理，因此漏掉了流式下载响应
   （FR-009）——这一条是本轮新增的教训，写在这里避免下次再按"预检通过＝可用"推断。

除这三点之外，浏览器已经可以直接使用本仓库中转的全部既有接口：
`/pair/claim`、`/pair/refresh`、`/devices`、`/devices/revoke`、`/files/down`（含 `Range` 续传）
都在 CORS 允许范围内（`access-control-allow-origin: *`，允许头含 `authorization`、`content-type`、`range`）。

## 2. 需求（可验收）

### FR-001 设备接入接受子协议形式的凭据

- `/link/device` 的握手 MUST 接受在 `Sec-WebSocket-Protocol` 中携带设备令牌，形如
  `dsh.device.<token>`（前缀固定，后缀为令牌原文）。
- 解析规则：取 `Sec-WebSocket-Protocol` 请求头，按 `,` 拆分、逐项去首尾空白，找出以 `dsh.device.`
  开头的一项，其后缀即令牌。
- **优先级**：只要 `Authorization: Bearer` 头存在且格式正确，MUST 一律以头为准并**完全忽略**子协议。
  这是"iOS 与连接器零感知"的根据。
- 头缺失时：子协议缺失、前缀不符、后缀为空、或令牌本身无效 —— 与现状一致返回 **HTTP 401**，
  不新增错误码、不改变错误文案语义（沿用既有 `missing bearer token` / `unknown ... device token`）。
- `/link/agent` MUST NOT 接受该通道（连接器仍只走头）。

### FR-002 明确回显被接受的子协议

- 中转 MUST 在握手响应中回显它接受的那一项子协议。理由：aiohttp 在"服务端未声明任何协议"时
  按规范**不回显**并仍完成握手（`aiohttp/web_ws.py` 内注释为 "No overlap found: Return no protocol
  as per spec"）。虽然规范允许客户端接受不回显，但把这条不确定性留在链路里不值得——
  显式回显把"浏览器是否接受"这个假设彻底消除。

### FR-003 CORS 允许 PUT

- `CORS_HEADERS` 的 `access-control-allow-methods` MUST 增加 `PUT`。
- 只改预检答案：实际路由集合不变，未注册的方法仍返回 405。

### FR-004 暴露 Content-Range

- `CORS_HEADERS` MUST 增加 `access-control-expose-headers: content-range, etag`。
  理由：这两个头都不在 CORS 安全响应头列表内，浏览器读不到就无法实现续传——
  `Content-Range` 给出"已经收到多少、总共多少"（进度与断点），`ETag` 给出"这份文件是哪个版本"
  （`If-Range` 的前置条件）。
- 同时 `access-control-allow-headers` MUST 继续允许 `range`，并增加 `if-range`
  （两者都会触发预检）。`if-range` 是**防拼错版本**的关键：文件在电脑上被改过之后，
  旧前缀接上新尾部会得到一份谁都没写过的文件；中转按 `If-Range` 返回整份（200）时，
  客户端才知道要丢弃旧前缀。
- 如果本仓库不希望暴露 `ETag`：客户端会退化为"只按 `Content-Range` 的偏移与总大小校验"，
  续传仍然可用，但在"同大小不同内容"的改动上无法自保。请评审时明确取舍。

### FR-004b `/devices` 回带调用方自己的 `deviceId`

- `GET /devices` 的响应 MUST 增加一个字段说明"哪一条是这次调用的设备"，建议形状：

  ```json
  {"ok": true, "items": [ … ], "deviceId": "dev_…"}
  ```

- 理由：`items` 含**账号下全部设备**（还包含 iOS 端），客户端只能按登记时的名字/型号去猜
  "本浏览器"是哪一条——同名同型号的两台设备就会标错，撤销时也容易撤错那一条。
  回带调用方的 `deviceId` 之后，匹配是精确的（改动量：把请求已解析出的 `deviceId` 原样回填）。
- 向后兼容：既有客户端只读 `items`，多一个字段不影响它们。

### FR-005 `/healthz` 增加能力标志

- `/healthz` 的响应 MUST 增加一个能力清单字段，建议形状（术语与连接器 `status` 已有的
  `capabilities` 对齐）：

  ```json
  {"ok": true, "version": 1, "capabilities": ["device-subprotocol-auth"]}
  ```

- 语义：该中转支持"设备接入子协议凭据"（FR-001/FR-002）与"CORS 允许 PUT"（FR-003/FR-004）。
  一个标志覆盖本请求的全部改动，便于客户端做一次判断。
- MUST 保持向后兼容：iOS 与连接器只读 `ok` / `version`；若本仓库有断言 `/healthz` 响应全等的
  测试，需同步放开（本条属于该测试的预期变更，不是回归）。
- 该能力**不区分**"能不能下载文件"：下载是否可用由响应头决定（FR-009），Web 端用一次
  真实请求判定文件能力（`PUT /files/up` 的预检是否放行），不需要为本轮新增能力项。

### FR-006 凭据卫生

- 子协议中的令牌 MUST NOT 出现在日志、异常消息、统计或诊断输出里。
  其敏感级别与 `Authorization` 头的令牌**完全相同**（长期凭据，默认 365 天）。
- 实现时确认：既有握手/帧相关的 debug 日志不会打印请求头。

### FR-007 零行为变化

- iOS 端、连接器、既有全部测试 MUST 无需任何改动即可继续通过。
- 限流、单 host 设备额度、每日出口额度、设备撤销等口径 MUST 不变
  （它们作用在 `deviceId` 上，与凭据通过哪个通道携带无关）。

### FR-008 不要求修既有行为

- 已知并已登记：同一 `deviceId` 的第二条 socket 会静默覆盖第一条（`hub.py` 的 `attach_device`
  注释里写明）。Web 端用"一个浏览器一条连接"规避，因此**本请求不要求**修该行为。

### FR-009 流式响应（`GET /files/down`）MUST 自带 CORS 响应头

**现象（2026-10-17 线上取证，Chromium 156；Web 端记录见
`23_dsh_webapp/specs/001-dsh-web-client/verification-record.md` §3.4）**：Web 端发起 `GET {relay}/files/down?...`，
请求本身已经带上 `Authorization` 与 `Range`，预检也通过了，但浏览器仍把整个下载判为失败：

```text
Access to fetch at 'https://<relay>/dsh-link/files/down?scopeId=<id>&path=<name>'
from origin 'http://127.0.0.1:5173' has been blocked by CORS policy:
No 'Access-Control-Allow-Origin' header is present on the requested resource.
```

**根因（已定位到行，不是猜测）**：

- `relay/api.py` 的 `cors_preflight` 中间件是"**先 `await handler(request)`，再给返回的响应补头**"：

  ```python
  response = await handler(request)
  response.headers["access-control-allow-origin"] = "*"
  return response
  ```

- 而 `files_down()` 返回的是**已经在 handler 内部 `prepare()` 过的流式响应**
  （`relay/api.py:1193` 构造 `web.StreamResponse`，`relay/api.py:1224`
  `await response.prepare(request)`，随后循环 `write()` 写出字节）。
- `prepare()` 一旦执行，状态行与响应头就已经发到网络上；中间件之后对
  `response.headers` 的修改**不会再被发送**（aiohttp 不报错，属于静默失效）。
- 于是：**预检 204 里什么都有（那是中间件直接返回的普通响应），真正的 200/206 下载响应里
  一个 CORS 头都没有**——"预检通过 ≠ 响应可读"。
- 这条教训本仓库自己已经写过一次：`relay/api.py:461` 的注释写着"浏览器拿跨域响应也必须有
  ACAO，否则预检通过了正文仍读不到（真实浏览器取证发现：预检放行 ≠ 响应可读）"。
  只是那一句只对**普通响应**成立——`StreamResponse.prepare()` 之后中间件就没有机会了，
  而现在的快闸里没有任何一条用例断言下载响应的头。
- iOS 与连接器不受影响：原生请求不做 CORS 校验。所以这个缺口只会在浏览器侧显形，
  与"第一轮全绿"可以同时成立。

**要求**：

- `GET /files/down` 的**所有**成功响应（`200` 整份、`206` 续传）MUST 在 `prepare()` **之前**
  写入下列头（建议抽成一个独立常量，避免把预检专用的头也发到 GET 上）：

  ```python
  #: 流式响应必须在 prepare() 之前自带 CORS 头：中间件在 handler 返回后才补，
  #: 那时响应头已经发出，补不上去（预检通过 ≠ 正文可读）。
  CORS_STREAM_HEADERS = {
      "access-control-allow-origin": "*",
      "access-control-expose-headers": "content-range, etag",
  }
  ```

- 改动位置：`files_down()` 里 `response = web.StreamResponse(status=status)` 之后、
  `await response.prepare(request)` 之前（与现有的 `Cache-Control` / `Accept-Ranges` 同一处），
  加一行 `response.headers.update(CORS_STREAM_HEADERS)`。
- `access-control-expose-headers` MUST 同时覆盖 `content-range` 与 `etag`：这两个头不在 CORS
  安全响应头列表内，浏览器读不到就显示不了进度、也算不出续传偏移与版本（与 FR-004 同一件事，
  只是那次只改了预检、没覆盖到流式响应的正文）。
- 若本仓库将来新增其他流式端点，MUST 适用同一规则，并在 `docs/RELAY-NOTES.md` 写明
  "流式响应要自带 CORS 头，中间件事后补无效"。
- MUST NOT 通过"把 CORS 头塞进 chunk 循环"或"在 handler 返回后改 headers"来实现——
  前者不可能，后者静默失效且难以测出。

**30 秒自检（不需要浏览器）**：拿一台已配对的设备令牌直接看一下响应头，普通 JSON 响应有
`access-control-allow-origin`、这一个没有，就是本条没做：

```bash
curl -s -D - -o /dev/null '<relay>/files/down?scopeId=<id>&path=<name>' \
  -H 'Authorization: Bearer <deviceToken>'
# 期望（修好后）：access-control-allow-origin: *
#                 access-control-expose-headers: content-range, etag
```

**不做**：不改 `GET /files/down` 的语义、分片、额度计算、`Range`/`If-Range` 行为；
不改预检（`OPTIONS`）路径；不新增端点。

**落地后由 Web 端复验**（本文件不要求本仓库搭浏览器环境跑完整下载）：Web 端会按
`quickstart.md` §3.4 用 5 MB 文件跑"整份下载 + 断网续传"，并把 `verification-record.md`
§3.4 的"阻塞"改判。本仓库只需给出 §6.1 第 7 条的快闸与 §6.2 第 3 步的取证结论。

### FR-010 `/healthz` 的 `capabilities` 与 `relay-contract.json` 对齐（低优先级，可拒绝）

**现状不一致**：

- `relay/api.py` 的 `/healthz` 只返回四项：`device-subprotocol-auth`、`persistent-pair-code`、
  `account-state`、`account-state-push`。
- 而 `docs/relay-contract.json` 的 `capabilities` 列了 19 项，其中包含 `file-transfer`。
- 结果：客户端按"能力清单"判断时只能判定"能不能直连"，判不了"能不能传文件"。
  Web 端目前的兜底是**多发一次空的 `PUT /files/up`**（放行即视作有文件能力），代价是一次多余请求。

**建议（二选一，请在本文件上写明结论）**：

1. `/healthz` 的 `capabilities` 增加 `file-transfer`（与 `relay-contract.json` 对齐）；
   新增字符串属于向后兼容的增量，既有客户端只做包含判断。Web 端会优先用该声明、省略预检。
2. 明确拒绝并说明理由。Web 端保持"空 PUT 预检"的判定，功能不受影响。

**不改**：`device-subprotocol-auth` 的语义与取值；其余能力项是否补充由本仓库自行决定。

## 3. 明确不做（边界承诺）

| 不做 | 说明 |
|---|---|
| 不新增端点、不新增帧类型 | `relay-contract.json` 的六张帧表一个字不改 |
| 不改数据库结构与字段 | 令牌仍走既有哈希查找口径，无迁移 |
| 不改 `dlp.py` / `hub.py` 的转发语义 | 中转仍不解析会话内容 |
| 不改连接器与 iOS 端 | 它们继续只走 `Authorization` 头 |
| 不放宽限流与额度 | `/pair/claim` 失败限流、设备额度、日额度一律不变 |
| 不引入 query 参数携带令牌 | 令牌会进 URL 面（历史、Referer、网关 URI 日志），见 §8 |

## 4. 实现指引

### 4.1 `relay/api.py`

1. 在 `bearer_token()` 旁新增取值函数，供设备接入使用（保持 `relay` 单向 import `api` 的既有分层）：

   ```python
   #: 浏览器无法在 WebSocket 握手设自定义头，因此设备接入额外接受子协议形式的凭据。
   #: 前缀固定，后缀是令牌原文（secrets.token_urlsafe 产物只含 A-Za-z0-9-_，是合法 token 字符）。
   DEVICE_SUBPROTOCOL_PREFIX = "dsh.device."

   def device_subprotocol_token(request: web.Request) -> str | None:
       """从 Sec-WebSocket-Protocol 里取出设备令牌；没有或不合法时返回 None。"""
       raw = request.headers.get("Sec-WebSocket-Protocol", "")
       for item in raw.split(","):
           candidate = item.strip()
           if candidate.startswith(DEVICE_SUBPROTOCOL_PREFIX):
               token = candidate[len(DEVICE_SUBPROTOCOL_PREFIX):].strip()
               return token or None
       return None
   ```

2. `CORS_HEADERS`：

   ```python
   CORS_HEADERS = {
       "access-control-allow-origin": "*",
       "access-control-allow-methods": "GET, POST, PUT, OPTIONS",
       "access-control-allow-headers": "authorization, content-type, range, if-range",
       "access-control-expose-headers": "content-range, etag",
       "access-control-max-age": "600",
   }
   ```

3. `healthz()` 增加 `capabilities`（FR-005）。
4. `devices_list()` 在响应里回填调用方的 `deviceId`（FR-004b）。
5. **流式下载响应自带 CORS 头（FR-009）**——这是本轮新增，改动只有一行，位置很关键：

   ```python
   #: 流式响应必须在 prepare() 之前自带 CORS 头：cors_preflight 中间件是在
   #: handler 返回之后才补头的，那时 StreamResponse 已经 prepare()，补不上去。
   CORS_STREAM_HEADERS = {
       "access-control-allow-origin": "*",
       "access-control-expose-headers": "content-range, etag",
   }
   ```

   ```python
   # files_down()，与既有的 Cache-Control / Accept-Ranges 同一处
   response = web.StreamResponse(status=status)
   response.content_type = "application/octet-stream"
   response.headers.update(CORS_STREAM_HEADERS)      # ← 新增（必须在 prepare 之前）
   response.headers["Cache-Control"] = "no-store"
   ...
   await response.prepare(request)
   ```

   为什么不能改中间件：中间件写法本身没错（普通 JSON 响应全靠它补头），错在这个 handler
   自己先 `prepare()` 了。中间件里无法补救：等它拿到响应时，`prepare()` 早已把响应头发出，
   再改 `headers` 不会报错也不会生效。若本仓库想统一治理，可以在 handler 里统一用
   `response.headers.update(CORS_STREAM_HEADERS)`（或封装一个 `stream_response()` 助手），
   但**头必须在 `prepare()` 之前写好**这一点不会变。

### 4.2 `relay/relay.py`

1. `_device_identity()`：头优先，其次子协议。建议保留原有两条错误文案，便于既有日志与测试不变：

   ```python
   async def _device_identity(request: web.Request) -> dict[str, Any]:
       store: Store = request.app["store"]
       token = bearer_token(request) or device_subprotocol_token(request)
       if not token:
           raise web.HTTPUnauthorized(text="missing bearer token")
       device = await asyncio.to_thread(store.device_by_token, token)
       if device is None:
           raise web.HTTPUnauthorized(text="unknown, revoked, or expired device token")
       wanted = request.query.get("agentId")
       if wanted and wanted != device["agentId"]:
           raise web.HTTPForbidden(text="agentId does not match the device token")
       return device
   ```

2. `_make_socket()`：显式回显被接受的子协议（FR-002）。把命中的那一项原样传进 `protocols`，
   aiohttp 只在"请求项与服务端声明项有交集"时回显：

   ```python
   def _make_socket(request: web.Request, limits: Limits) -> web.WebSocketResponse:
       echoed = [
           item.strip()
           for item in request.headers.get("Sec-WebSocket-Protocol", "").split(",")
           if item.strip().startswith(DEVICE_SUBPROTOCOL_PREFIX)
       ]
       return web.WebSocketResponse(
           max_msg_size=limits.max_frame_bytes,
           heartbeat=30.0,
           receive_timeout=None,
           autoping=True,
           compress=False,
           protocols=echoed,          # 空列表等价于现状：不回显
       )
   ```

   注意：`echoed` 只可能包含 `dsh.device.<token>` 这一项（同一连接不会同时请求别的子协议）；
   若不希望把令牌回显给客户端，可改为回显一个不含令牌的等值标记——但那需要客户端同时接受两个
   不同的请求/响应值，规范上不允许（服务端只能选客户端请求过的项），因此保持原样回显。

### 4.3 协议文档与记录

- `docs/RELAY-PROTOCOL.md`：§2 端点表补一行说明"设备接入可用子协议携带令牌"，
  §2.2 鉴权失败段落补一句优先级与失败口径（头优先、无凭据 401）。
- `docs/RELAY-NOTES.md`：按既有格式记一条"实现与规范的偏差/决定"，写明这是浏览器兼容通道。
- `CHANGELOG.md`：按本仓库节奏记一条。
- `relay-contract.json`：建议把该能力登记进机器可读契约（新增 capabilities 相关字段或沿用既有段落），
  因为三端都有读该文件的测试；若本仓库认为不属于帧契约，请在评审时明确，Web 端会改用探测判定。

## 5. 对外契约：Web 端会怎么使用（对齐目标）

| 用途 | 形态 | 是否需要本仓库改动 |
|---|---|---|
| 配对换令牌 | `POST {relay}/pair/claim`，body 含 `pairCode` / `deviceName` / `deviceModel` / `appVersion` | 否（已可用） |
| 建立设备连接 | `new WebSocket("wss://{relay}/link/device?agentId=<agentId>", ["dsh.device." + deviceToken])` | 是（FR-001/002） |
| 心跳 | 每 20s 发 `{"t":"ping","ts":…}`，60s 无 `pong` 判定断线 | 否 |
| 重连 | 指数退避 1s→2s→…→30s，±20% 抖动 | 否 |
| 大帧重组 | relay→device 可能把一个大帧拆成多条 WS 消息，客户端必须自行重组 | 否 |
| 设备列表 / 撤销 | `GET /devices`、`POST /devices/revoke`（Bearer 头）；需要 `deviceId` 精确标出"本浏览器" | 是（FR-004b，一行回填） |
| 文件上传 / 下载 | `PUT /files/up`、`GET /files/down`（`Range` + `If-Range` 续传） | 是（FR-003/004）；**下载的 200/206 响应还必须自带 CORS 头**（FR-009），否则浏览器读不到正文 |
| 能力探测 | 读 `/healthz` 的 `capabilities`；缺失时提示"中转需升级"，不静默失败 | 是（FR-005） |

Web 端的承诺（对应上面的边界）：一次连接只请求一个子协议；子协议只用于鉴权；
令牌只保存在浏览器本地，不写进 URL、不写进日志；不依赖任何本次未列出的中转行为。

下载的具体往返（与 FR-009 对应，便于实现方对齐）：

1. 首次：`GET /files/down?scopeId=<id>&path=<name>`，只带 `Authorization: Bearer <token>`；
   期望 `200`，读 `ETag` 与（若有）`Content-Range`。
2. 中断后续传：同一 URL 带 `Range: bytes=<已收字节>-`，并在有 `ETag` 时带 `If-Range: <该 ETag>`；
   期望 `206` + `Content-Range: bytes <起始>-<末>/<总>`。
3. 版本已变：中转按 `If-Range` 语义回 `200` 整份；Web 端丢弃已收前缀、整份重来（**绝不拼接**）。
4. 任一步拿不到 `content-range`/`etag`（因为没 expose），Web 端只能按"从零重下"降级——
   这正是当前线上发生的事，也是 FR-009 要求暴露这两个头的原因。

## 6. 测试与验证要求

### 6.1 快闸（可程序化，必须先全绿）

1. **扩展** `relay/tests/test_pair_api.py` 中的设备鉴权用例（现有 `test_websocket_rejects_unknown_tokens`
   就在该文件，line ~143）：
   - 子协议携带无效令牌 → 401
   - 无头且无子协议 → 401（现状已覆盖，确认不被新逻辑破坏）
   - 头与子协议同时存在且指向**不同**设备 → 以头为准（用头对应的设备身份通过）
2. **新增**：仅子协议 + 有效令牌 → 升级成功并能收发：
   - `ws = await client.ws_connect(f"/link/device?agentId={agent['agentId']}", protocols=[f"dsh.device.{token}"])`
   - 断言握手成功；**断言 `ws.protocol == f"dsh.device.{token}"`**（这才是真正锁住 FR-002 的断言：
     aiohttp 客户端在服务端不回显时也会放行，因此只断言"连上了"不足以覆盖回显要求）；
     发 `{"t":"ping"}` 收到 `pong`。
3. **新增** CORS 预检断言（现状：`rg OPTIONS relay/tests` 无任何结果，预检目前没有断言）：
   - `OPTIONS /files/up` → 204，且 `access-control-allow-methods` 含 `PUT`
   - 响应头 `access-control-expose-headers` 含 `content-range`
4. **扩展** `/healthz` 断言：`capabilities` 含 `device-subprotocol-auth`；
   同步放开任何"响应全等"式断言（属预期变更，见 FR-005）。
5. **新增**：`GET /files/down` 带 `Range` + `If-Range` 的用例——版本一致时回 206 与
   `Content-Range`/`ETag`；`If-Range` 过期时回 200 + 整份（**绝不拼接**）；
   预检对 `range` 与 `if-range` 都放行（见 FR-004）。
6. **新增**：`GET /devices` 的响应含调用方自己的 `deviceId`（见 FR-004b）。
7. **新增（FR-009，必须有）**：直接断言**流式下载响应自己**带 CORS 头，而不是只断言预检。
   这一条是抓 FR-009 的唯一快闸；漏了它就只能靠真实浏览器取证发现（上一轮就是这样漏掉的）。
   用本仓库既有的测试替身写法（`relay/tests/test_files_down.py` 的 `FetchStub`）：

   ```python
   async def test_streamed_download_response_carries_cors_headers(client, provisioned):
       agent_ws = await open_agent(client, provisioned)
       device = await claim_device(client, provisioned)
       await drain(agent_ws)
       body = b"z" * (1 << 20)

       stub = FetchStub(agent_ws, body)
       task = asyncio.create_task(stub.run())
       full = await client.get(down_url(device, scopeId="s1", path="report.bin"),
                               headers=device_auth(device))
       assert full.status == 200
       # 这一行是 FR-009 的核心：正文响应自己的头，不是预检的头
       assert full.headers["access-control-allow-origin"] == "*"
       exposed = full.headers["access-control-expose-headers"].lower()
       assert "content-range" in exposed and "etag" in exposed
       assert full.headers["etag"]
       assert await full.read() == body
       await task

       stub_part = FetchStub(agent_ws, body)
       task_part = asyncio.create_task(stub_part.run())
       part = await client.get(down_url(device, scopeId="s1", path="report.bin"),
                               headers={**device_auth(device), "Range": "bytes=1024-"})
       assert part.status == 206
       assert part.headers["access-control-allow-origin"] == "*"
       assert part.headers["content-range"].startswith("bytes 1024-")
       assert await part.read() == body[1024:]
       await task_part
       await agent_ws.close()
   ```

   - 断言必须落在**正文响应**上：`OPTIONS` 本来就有头，只测预检测不出这个缺口。
   - 200 与 206 都要测：两条路径共用同一个 `StreamResponse`，但 `206` 多走 `Content-Range` 分支，
     最容易在这里漏掉 expose-headers。
   - 读 body 是必须的（释放连接、避免用例互相干扰），但头在状态行之后立刻可读，先读后读都行。
8. **（仅当接受 FR-010）** 扩展 `/healthz` 断言：`capabilities` 含 `file-transfer`，
   且 `npm run check:contracts` 仍通过。

### 6.2 慢闸：真实进程 + 真实浏览器（这条链路唯一的可信证据）

1. 沿用 `relay/tests/test_caddy_runtime.py` 的做法：真实 Caddy + 真实 relay 进程 + 真实 HTTP 请求，
   验证经网关后设备接入仍正常（含子协议被网关原样转发、升级不被拦）。
2. 真实浏览器验证一次（人工或脚本化，务必落在**真实浏览器**上，不是 aiohttp 客户端）：
   - 在 relay 主机上起一个本地页面：`python3 -m http.server`
   - 用 `http://127.0.0.1:<port>` 打开它（用 `http://` 打开，避免 https 页面连 `ws://` 被混合内容策略拦截），
     页面里执行：

     ```js
     const ws = new WebSocket('ws://127.0.0.1:8787/link/device?agentId=<agentId>',
                              ['dsh.device.<deviceToken>'])
     ws.onopen = () => ws.send(JSON.stringify({ t: 'ping', ts: Date.now() }))
     ws.onmessage = (event) => console.log('frame', event.data)
     ```

   - 期望：`onopen` 触发；`ws.protocol === 'dsh.device.<deviceToken>'`（回显生效）；收到 `pong`。
   - 再用同一个页面验证上传通道不被 CORS 拦（用 1 字节 body 即可）：

     ```js
     await fetch('http://127.0.0.1:8787/files/up?sessionId=<id>&name=<name>&bid=<bid>', {
       method: 'PUT',
       headers: { Authorization: 'Bearer <deviceToken>' },
       body: new Uint8Array(1),
     })
     ```

   - 期望：得到业务响应（例如 4xx/5xx 的业务错误码均可），**不是** CORS 拒绝。
3. **真实浏览器验证下载（FR-009，必须做；上一轮就是漏了这一步）**。
   在同一个本地页面里执行（`http://` 打开，避免 https 页面连 http 端点被混合内容策略拦）：

   ```js
   const base = 'http://127.0.0.1:8787'
   const H = { Authorization: 'Bearer <deviceToken>' }
   const q = 'scopeId=session-x&path=report.bin'

   // ① 整份：200，且 CORS 头可读
   const full = await fetch(`${base}/files/down?${q}`, { headers: H })
   console.log('status', full.status,
               'acao', full.headers.get('access-control-allow-origin'),
               'etag', full.headers.get('etag'),
               'range', full.headers.get('content-range'))
   const whole = await full.arrayBuffer()
   console.log('bytes', whole.byteLength)            // 应等于文件大小

   // ② 续传：Range + If-Range 命中版本 → 206，Content-Range 可读
   const etag = full.headers.get('etag')
   const part = await fetch(`${base}/files/down?${q}`, {
     headers: { ...H, Range: 'bytes=1024-', 'If-Range': etag },
   })
   console.log('part', part.status, part.headers.get('content-range'))  // 206, bytes 1024-<末>-<总>

   // ③ 版本过期：If-Range 对不上 → 200 整份（绝不拼接）
   const stale = await fetch(`${base}/files/down?${q}`, {
     headers: { ...H, Range: 'bytes=1024-', 'If-Range': '"dsh-stale"' },
   })
   console.log('stale', stale.status, (await stale.arrayBuffer()).byteLength)  // 200 + 整份长度
   ```

   期望：

   | 步骤 | 期望 | 失败时说明什么 |
   | --- | --- | --- |
   | ① | `status === 200`、`acao === '*'`、`etag` 非空、字节数等于文件大小 | `acao` 为 null ⇒ 正文响应缺 CORS（本轮缺口）；`etag` 为 null ⇒ expose-headers 没生效 |
   | ② | `status === 206`、`content-range` 形如 `bytes 1024-<末>/<总>` | `content-range` 为 null ⇒ 同上，续传的进度与断点都读不到 |
   | ③ | `status === 200`，字节数等于整份 | 回 `206` ⇒ `If-Range` 的比较被绕过，续传会拼出"谁都没写过"的文件 |

   注意：**预检通过不代表正文可读**。第 1 步的 `OPTIONS` 一早就是 204 + 全套 CORS 头，
   缺失只出现在 `200/206` 的正文响应上——所以这一节必须真的去 `fetch` 一次并读一次 body，
   不能只看"请求没报错"。

4. 把浏览器名称与版本、结论写进改动记录。若本仓库的三级渠道里有跑不了的一级，
   按既有口径留痕（形如 `L3: 未跑 — <理由>`），不得静默跳过。

### 6.3 命令清单与预期

```bash
cd relay && .venv/bin/python -m pytest -q                            # 全绿
npm run check:secrets                                                # 通过（新增文件不得含真值）
npm run check:docs                                                   # 通过（本文件在仓库根目录，不在 docs/ 清单内）
npm run check:contracts                                              # 通过（若登记 capabilities 契约则需同步）
npm run check:lanes -- --changed relay/api.py relay/relay.py         # 按矩阵给出必须取证的渠道
```

## 7. 验收判据（DoD）

- [ ] FR-001 ~ FR-008（含 FR-004b）每条都有对应测试或证据
- [ ] **FR-009**：`GET /files/down` 的 200 与 206 响应自带 `access-control-allow-origin: *`
      与 `access-control-expose-headers: content-range, etag`（§6.1 第 7 条）；
      真实浏览器按 §6.2 第 3 步跑完三步（整份 / 续传 / If-Range 过期），并把浏览器版本与结论写进改动记录
- [ ] **FR-010**：接受则在 `/healthz` 声明 `file-transfer` 且 `check:contracts` 通过；
      拒绝则在本文件上写明结论（Web 端保持"空 PUT 预检"的兜底，功能不受影响）
- [ ] §6.1 的快闸用例全部新增/扩展并通过
- [ ] §6.2 真实进程 + 真实浏览器取证已取得，并记录浏览器版本与结论
- [ ] iOS 端与连接器**零改动**，其既有测试全绿
- [ ] `docs/RELAY-PROTOCOL.md` / `docs/RELAY-NOTES.md` / `CHANGELOG.md` 已更新
- [ ] 回滚路径验证过（FR-001 ~ FR-004 的改动、FR-009 的一行、FR-010 的一个字符串可各自独立 revert；
      既有 `Authorization` 头通道不受影响）

## 8. 风险、兼容与回滚

| 风险 | 说明 | 缓解 |
|---|---|---|
| 令牌进入网络面 | 子协议是请求头，不进 URL；网关是否记录请求头取决于其日志配置（本仓库 `deploy/Caddyfile.snippet` 未见访问日志指令） | FR-006 禁止自行记录；不采用 query 方案 |
| 子协议字符约束 | 若将来令牌生成方式改变（出现 `=`、`+`、`,` 等非法 token 字符），该通道会失效 | 实现里对不合法项返回 `None` 并落入既有 401；在 `docs/RELAY-PROTOCOL.md` 写明字符约束 |
| `/healthz` 形状断言 | 若存在"响应全等"断言会变红 | 已列为预期变更（FR-005） |
| 浏览器兼容 | 若某浏览器对子协议回显有别的解释 | FR-002 显式回显 + §6.2 真实浏览器取证 |
| 流式响应头顺序 | `files_down` 先 `prepare()` 再写 chunk；在 `prepare()` 之后改 `response.headers` **不报错也不生效**，只能靠响应头断言或真实浏览器发现 | FR-009 要求在 `prepare()` 之前写头；§6.1 第 7 条把它变成可复跑的断言，§6.2 第 3 步再校验一次 |
| 网关是否会改写响应头 | Caddy 默认透传，但若部署里有 `header` 指令做删除/覆盖，CORS 头可能被抹掉 | 按 §6.2 第 3 步在**经网关的真实地址**上取证，而不是只测 loopback |
| 回滚 | 半途回退 | FR-009 是独立一行（headers.update），单点 revert 后回到"浏览器下载被拦、iOS 不受影响"的状态；FR-010 只是一个字符串，revert 不影响任何客户端 |

## 9. 待本仓库评审决定的开放项

1. `/healthz` 的能力字段名是否用 `capabilities`（本文件建议与连接器 `status` 的既有术语对齐）。
2. 该能力是否登记进 `relay-contract.json`；若不登记，请明确告知，Web 端改用探测判定。
3. 是否接受把 `PUT` 加进全局预检答案；若希望更窄，可改为按路径分支（中间件是全局的），
   但请在本文件上写明结论，Web 端据此调整探测逻辑。
4. 本文件的去留：留在仓库根目录、移入 `docs/`（需同时登记进 `check-docs` 清单）、或落地后删除。
5. 是否暴露 `ETag`（FR-004）：暴露则续传能防"同大小不同内容"的错版本拼接；不暴露则
   续传仍可用，但少了这道保险。请在评审时给结论，Web 端按结论决定是否把"发现版本变化"
   的提示降级为"仅按偏移与总大小校验"。
6. **FR-009 的实现方式**：本文件建议"每个流式 handler 自己写头"（最小、最直白）。
   若本仓库更愿意统一治理（例如给 `StreamResponse` 包一层 `stream_with_cors()`），
   只要保证 `prepare()` 之前头已就位即可；请在本文件上写明选哪种，Web 端不关心实现形状。
7. **FR-010 采纳与否**：接受则 `/healthz` 多一个字符串；拒绝也没有功能影响——但请明确回复，
   否则 Web 端会一直保留那次多余的预检请求。

---

## 10. 本仓库结论（2026-10-17）

### FR-009 已实现（必做项）

- `relay/api.py` 新增 `CORS_STREAM_HEADERS`（`access-control-allow-origin: *` +
  `access-control-expose-headers: content-range, etag`）；`files_down()` 在
  `StreamResponse.prepare()` **之前**写上这组头，位置与 `Cache-Control` / `Accept-Ranges` 相同。
  实现形状按 §9 第 6 项的建议 1（handler 自己写头），没有包一层助手。
- 中间件未改动：普通响应仍由它补头；`OPTIONS` 路径未改。
- **§6.1 第 7 条**：`relay/tests/test_files_down.py::test_streamed_download_response_carries_cors_headers`
  直接断言 200 与 206 的**正文响应**头（`acao == "*"`、expose 含 `content-range, etag`、
  `etag` 非空、正文完整、`206` 的 `content-range` 自 `bytes 1024-` 起）。反向确认过：删掉那一行，
  该用例即报 `KeyError: 'access-control-allow-origin'`。
- **§6.2 第 3 步**：Chromium 148.0.7778.96（Playwright headless）+ 真实 Caddy + 真实 relay 进程 +
  5 MB 文件，三条路径全部通过：整份 `200`（长度与 SHA-256 与文件一致）、续传 `206`
  （`content-range: bytes 1024-5242879/5242880`，正文 SHA-256 等于 `body[1024:]`）、
  `If-Range` 过期 `200` 整份（不拼接）。负对照（去掉那一行的副本）复现了线上那条
  `blocked by CORS policy: No 'Access-Control-Allow-Origin' header is present`。
  浏览器版本、原始输出与判据见 `maintainers/2026-10-17-fr009-browser-evidence.md`。
- 文档：`docs/RELAY-NOTES.md` 第 16 条（流式响应要自带 CORS 头，中间件事后补无效）、
  `docs/RELAY-PROTOCOL.md` 端点表后一段、`CHANGELOG.md`。

**一处口径修正，请 Web 端按此写判据**：§6.2 第 3 步期望表里的 `acao === '*'` 在页面脚本里
取不到——`access-control-allow-origin` 不在 CORS 安全响应头列表内，浏览器只用它做放行判定，
不交给脚本（实测同一页面对 `/healthz` 的普通 JSON 响应读到的也是 `null`）。照原文写，
修好之后也会判失败。可用判据是：`fetch` 正常 resolve、正文长度与哈希正确、`etag` 与
`content-range` 可读——后两者可读本身就证明 expose 生效。本仓库不会为了满足该断言把 ACAO
加进 expose 列表。

### FR-010 决定：**采纳**

- `/healthz` 的 `capabilities` 增加 `file-transfer`，与 `docs/relay-contract.json` 的能力词表
  逐字一致；语义是"这份中转有 `PUT /files/up` 与 `GET /files/down`"，连接器版本是否支持后台
  传输仍由下载响应自己回答。既有客户端只做包含判断，属向后兼容的增量。
- 覆盖：`relay/tests/test_pair_api.py::test_healthz_advertises_file_transfer_capability`；
  `npm run check:contracts` 通过（能力词表比对的是连接器 `SERVER_CAPABILITIES`，本轮未动）。
- Web 端可以据此省略那次空的 `PUT /files/up` 探测，不必再保留兜底。
- 其余能力项是否补充由本仓库后续自行决定，本次不动。

### 其它

- 回滚：FR-009 是一个常量 + 一行 `headers.update`，FR-010 是一个字符串，可各自独立 revert；
  既有 `Authorization` 头通道（iOS / 连接器）不受影响。删掉那一行后跑全量：
  643 passed / 1 failed（唯一失败即 FR-009 的新用例）/ 1 skipped，回滚边界实测过。
- 渠道：L1/L2 的 `relay-tests` 场景均 pass（`.lanes/runs/l1/20261017T052455Z-relay-tests`、
  `.lanes/runs/l2/20261017T052456Z-relay-tests`，各 644 passed / 1 skipped，L2 是 Python 3.12
  + 真 Caddy 的与 CI 同源命令）。
- **已部署**（2026-10-17）：`https://www.storyworld.site/dsh-link`，构建号 `20261017.1330`。
  部署后公开面已验：`/healthz` 的 `capabilities` 含 `file-transfer`；`OPTIONS /files/up` 仍
  放行 `PUT` 并 expose `content-range, etag`；连接器重启后自动重连、设备被重新采纳。
  `L3: 未跑 — 没有干净 guest；生产中转的三步正文取证由 Web 端在真实地址完成`（本仓库不在生产
  账户下造临时设备去取那几个字节）。
- 零回归：连接器 `npm test` 363 passed；DSHKit `swift test` 482 executed / 2 skipped、
  0 failures，另 166 项 swift-testing 全过；`check:secrets` / `check:docs` / `check:contracts`
  均通过。
