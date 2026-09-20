# 架构与关键决策

> 面向：实现者 · 状态：stable · 最近核对：2026-09-20

## 1. 为什么不重写协议

DSH 电脑端本身就是一个「客户端 + host」结构：浏览器里的 UI 通过 HTTP RPC 与一条
多路复用 WebSocket 跟 host 通信。这个协议是 schema 驱动的、可枚举的、有严格校验的。

因此手机端的做法不是「复刻 DSH 的功能」，而是**成为 DSH 的另一个客户端**。
带来的结果：

- 电脑端与手机端天然共享同一批会话、同一条事件流，不需要任何同步逻辑。
- 电脑端上线的功能，只要落在已有的 RPC / 事件面上，手机端不需要改协议层就能用。
- 手机上回答一个提问，电脑端那个正在等待的 `ask_user_question` 立刻继续——
  因为它本来就是同一个 host 上的同一个 continuation。

这条路线的前提是「协议可枚举」。这一点在动手前用实测确认过：对任一端点发送不合法
参数，host 会回显它期望的字段名，例如

```
typert gateway: workspaceFiles/list: args fields do not match the descriptor:
missing "workspaceFileScopeId", "path"; unexpected "__probe__"
```

于是 `docs/dsh-rpc-catalog.json` 里的 36 个方法签名是**测出来的**，不是猜的。

## 2. 传输抽象

`DSHCarrier` 是唯一的分界线，两个实现完全等价：

| 实现 | 路径 | 用途 |
|---|---|---|
| `HTTPCarrier` | 直接 HTTP + WS | 同一局域网，最快；也是协议的参考实现 |
| `LinkCarrier` | 单条 WSS 上的 DLP 隧道 | 电脑无公网 IP 时 |

`DSHClient` 与所有上层代码只认 `DSHCarrier`，所以「直连」和「中转」对 UI 没有区别，
而 DLP 只是把同样的逻辑协议装进一条连接里转发——中转层不认识 session，也不解析事件，
这使得 DSH 升级不会破坏中转。

## 3. 三个踩过的坑（都已修复并被测试覆盖）

这些都是**只有对着真实 host 才会暴露**的问题，值得记录：

### 3.1 mux 必须用文本帧

WebSocket 的 `open` 帧如果用二进制发送，host 会以 `1003 text messages required`
关闭连接。客户端的 `receive()` 报出来的是 `ENOTCONN`（"Socket is not connected"），
与真实原因完全无关。修复：`MuxConnection` 一律 `.string` 发送。

### 3.2 URLSession 在 WebSocket 升级请求上丢弃手写的 `Cookie` 头

`URLRequest.setValue(_:forHTTPHeaderField: "Cookie")` 对普通 HTTP 请求有效，对
`URLSessionWebSocketTask` 的升级请求**无效**——抓包可见该头根本没发出去。
结果是 WS 握手拿到 401、连接被关，而客户端只能看到「socket 未连接」。

另外，私有的 `HTTPCookieStorage()` 虽然可以作为 `URLSessionConfiguration`
的一部分被接受，却不会被 URL loading system 采用；必须用 `.shared`。

修复：认证后把 Cookie 写进 `HTTPCookieStorage.shared`，由系统自动附加。
Cookie 本身是 host 作用域，因此共用进程级存储不会把凭据泄漏给别的 authority。

### 3.3 子代理会话需要复合地址

`session/page` 与 `session/follow` 不接受裸的子会话 id：

```
subagent/unauthorized: subagent mode does not match the supplied address
```

正确地址是 `{kind:"subagent", parentSessionId, childSessionId, mode}`，而 `mode`
（`one-shot` / `continuable`）只存在于会话列表的 `projections.values.subagent.mode`。
`SessionSummary.address` 负责把这个地址还原出来，`testSubagentTranscriptIsAddressable`
盯着它。

## 4. 时间线折叠

host 的日志是扁平的 `{type, seq, time, data}` 事件流，其中工具调用与工具结果是
两条独立事件。手机需要一条可直接渲染的列表，于是 `ChatTimeline` 负责：

- 把 `assistant/message` 里的 reasoning / text / tool-call 块拆成独立行；
- 按 `callId` 把 `tool/result` 合并回对应的工具卡片；
- 用 `assistant-stream` 的 `text-delta` / `reasoning-delta` 渲染未提交的实时气泡，
  并在 `assistant/message` 提交时丢弃气泡（提交的才是权威）；
- 遇到匹配不上调用的结果（被裁剪的历史页）也不丢，降级为一条提示行。

这部分放在 DSHKit 而不是视图层，就是为了能对着抓下来的真实日志做单元测试——
`TimelineTests`（合成事件）与 `testRealHistoryFoldsIntoARenderableTimeline`
（真实日志）都在守它。

## 5. 乐观回显与去重

发送消息时立即往时间线插入一行，否则在网络往返期间界面是空的。为了不让 host 的
确认再插一行，这一行用 **requestId** 作为身份：`session/prompt` 的 `requestId`
会被 host 持久化到消息 source 的 `rpcId` 上，回来的事件携带同一个 id，
`append` 于是按 id 覆盖而不是新增。

**行身份必须是持久记录的纯函数**：`event.seq`（转发、推理、工具块还要加上块下标）、
`rpcId`、`callId`，或者轮次号。不能掺进折叠过程自己的状态（早期版本掺了一个自增
计数器），因为**重进一个会话会把同一段记录再折叠一次**：`ChatModel.open` 先恢复
缓存的转写，再用 follow 快照 `merge` 一遍。计数器每折一次就给出一个新 id，于是每
进一次会话就多出一份回答，而按轮次号命名的分隔线始终只有一条——这正是「新会话退回
列表再进来会多生成一次回答」的样子。同一段记录折两次必须得到同样的行，
`TimelineTests.testReopeningASessionDoesNotDuplicateItsReplies` 守着这条不变量。

## 6. 事件连接只开一条

`$events` 的每条流都有自己的 `clientId`，而 waterfall 的应答必须带上开启该流时拿到的
`clientId`。如果每个界面各开一条，同一条提问会被多个 `clientId` 抢答。

因此 `HostEventHub` 独占这一条流，向界面扇出，并成为唯一的应答者。待处理提问被提升为
一等状态（`Hub.pending`），在聊天页固定在输入框上方——因为放着不答会真的卡住电脑端。

## 7. 视觉一致性

`DSHTheme` 是电脑端 `--dsw-*` 令牌的转录：`bg-layer-1/2/3`、`label-primary/secondary/
tertiary`、`border-l1..l4`、品牌蓝 `#4D6BFE`（DeepSeek 官方蓝，全 App 唯一的强调色）、
圆角 12、正文 16/24、字重 400/500。命名保持与电脑端一致，这样将来令牌变了，映射是机械的。

边框令牌写成八位十六进制（`0xRRGGBBAA`，如 `0xFFFFFF0F` = 白 6%）。App 里只有
`border1/2/3` 是这种写法，`Color(hex:)` 见到八位值就按 RGBA 解析。少写这两位会变成
不透明色：深色模式下 `0xFFFFFF0F` 曾被当成 RGB 读成亮黄，整屏分隔线发黄就是这么来的。

App 图标用的是同一套令牌：DeepSeek 蓝三段渐变 + 白色终端提示符 `>_`（App 内
`terminal.fill` 的同一个意象），深色变体是近黑蓝底加一层蓝光。图由
`scripts/dev/make-app-icon.py` 画出来（4 倍超采样再缩到 1024）——「只有一张 PNG、
没人知道怎么改」本身就是设计债，改设计改脚本再跑一次，浅色深色两张一起重出。

## 8. 已知边界

- `directoryPicker/pick` 在无原生选择器的 host 上返回 `directory-picker/unavailable`，
  手机端不做该入口。
- 冷门 Cordis 动态插件界面不在原生实现范围内，用内嵌 `WKWebView` 兜底。
- 权限预设由 host 的 session 决定，没有对应 RPC；手机上切换只影响本地显示，
  权威值随下一次 projection 回来。
