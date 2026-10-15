# 变更请求：让浏览器客户端能直连既有中转（最小支持改动）

**提出方**：DSH Web 端项目（同机部署的 Web 客户端，浏览器直连中转）
**目标仓库**：本仓库（19_dsh_iosapp）
**提出日期**：2026-10-15
**状态**：待评审；本仓库处理完这份请求、Web 端才能进入实现阶段

**这份文件的作用**：本仓库的实现方与验证方**只看这份文件**即可完成开发与验证，不需要回问提出方。
文件包含：为什么改、改哪几处、精确到函数的实现指引、必须补的测试、真实浏览器取证方式、
验收判据、边界承诺、风险与回滚。

**边界（承诺）**：只做"让浏览器能直连既有中转"所需的最小改动。不改帧格式、不改数据库结构、
不新增端点、不改连接器与 iOS 端、不改限流与额度口径。

---

## 1. 背景：两条硬事实

Web 端的目标是**由用户浏览器直接连接本仓库的中转**（不设中间层），当作一台与 iOS App 并列的
设备接入同一台 DSH host。但浏览器有两条限制：

1. **浏览器无法在 WebSocket 握手时设置自定义请求头**（`new WebSocket()` 不支持自定义头），
   而本仓库中转的设备接入只认 `Authorization: Bearer` 头（`relay/api.py` 的 `bearer_token`）。
   iOS 能做到是因为 `URLSession` 允许设头（`ios/DSHMobile/DSHKit/Sources/DSHKit/LinkCarrier.swift`
   在升级请求上设 `Authorization`）。
2. **既有 CORS 允许的方法不含 `PUT`**（`relay/api.py` 的 `CORS_HEADERS` 为
   `"GET, POST, OPTIONS"`），而手机上传文件走的是 `PUT /files/up`。浏览器发起该请求必先做预检，
   预检答案里没有 `PUT` 就会被拦下。

除这两点之外，浏览器已经可以直接使用本仓库中转的全部既有接口：
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

- `CORS_HEADERS` MUST 增加 `access-control-expose-headers: content-range`。
  理由：`Content-Range` 不在 CORS 安全响应头列表内，浏览器读不到它就无法实现/显示续传进度
  （`GET /files/down` 的 `Range` 续传依赖这个头）。

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
       "access-control-allow-headers": "authorization, content-type, range",
       "access-control-expose-headers": "content-range",
       "access-control-max-age": "600",
   }
   ```

3. `healthz()` 增加 `capabilities`（FR-005）。

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
| 设备列表 / 撤销 | `GET /devices`、`POST /devices/revoke`（Bearer 头） | 否（已可用） |
| 文件上传 / 下载 | `PUT /files/up`、`GET /files/down`（`Range` 续传） | 是（FR-003/004） |
| 能力探测 | 读 `/healthz` 的 `capabilities`；缺失时提示"中转需升级"，不静默失败 | 是（FR-005） |

Web 端的承诺（对应上面的边界）：一次连接只请求一个子协议；子协议只用于鉴权；
令牌只保存在浏览器本地，不写进 URL、不写进日志；不依赖任何本次未列出的中转行为。

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
3. 把浏览器名称与版本、结论写进改动记录。若本仓库的三级渠道里有跑不了的一级，
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

- [ ] FR-001 ~ FR-008 每条都有对应测试或证据
- [ ] §6.1 的快闸用例全部新增/扩展并通过
- [ ] §6.2 真实进程 + 真实浏览器取证已取得，并记录浏览器版本与结论
- [ ] iOS 端与连接器**零改动**，其既有测试全绿
- [ ] `docs/RELAY-PROTOCOL.md` / `docs/RELAY-NOTES.md` / `CHANGELOG.md` 已更新
- [ ] 回滚路径验证过（三处改动可独立 revert，既有头通道不受影响）

## 8. 风险、兼容与回滚

| 风险 | 说明 | 缓解 |
|---|---|---|
| 令牌进入网络面 | 子协议是请求头，不进 URL；网关是否记录请求头取决于其日志配置（本仓库 `deploy/Caddyfile.snippet` 未见访问日志指令） | FR-006 禁止自行记录；不采用 query 方案 |
| 子协议字符约束 | 若将来令牌生成方式改变（出现 `=`、`+`、`,` 等非法 token 字符），该通道会失效 | 实现里对不合法项返回 `None` 并落入既有 401；在 `docs/RELAY-PROTOCOL.md` 写明字符约束 |
| `/healthz` 形状断言 | 若存在"响应全等"断言会变红 | 已列为预期变更（FR-005） |
| 浏览器兼容 | 若某浏览器对子协议回显有别的解释 | FR-002 显式回显 + §6.2 真实浏览器取证 |
| 回滚 | 三处改动互相独立，均不改变既有通道的语义 | 单点 revert；Web 端在 `capabilities` 缺失时提示"中转需升级"，不静默失败 |

## 9. 待本仓库评审决定的开放项

1. `/healthz` 的能力字段名是否用 `capabilities`（本文件建议与连接器 `status` 的既有术语对齐）。
2. 该能力是否登记进 `relay-contract.json`；若不登记，请明确告知，Web 端改用探测判定。
3. 是否接受把 `PUT` 加进全局预检答案；若希望更窄，可改为按路径分支（中间件是全局的），
   但请在本文件上写明结论，Web 端据此调整探测逻辑。
4. 本文件的去留：留在仓库根目录、移入 `docs/`（需同时登记进 `check-docs` 清单）、或落地后删除。
